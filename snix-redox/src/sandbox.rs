//! Namespace sandboxing for Redox build isolation.
//!
//! Restricts a builder process's scheme namespace so it can only access
//! the schemes needed for the build. Uses Redox's native namespace
//! mechanism (`mkns` + `setns`) — the Redox equivalent of Linux
//! namespaces + seccomp, but with a single, simpler API.
//!
//! ## How it works
//!
//! Redox processes access all I/O through *schemes* (`file:`, `net:`,
//! `display:`, etc.). Each process has a namespace fd that controls
//! which schemes are visible. `mkns` creates a new namespace containing
//! only the specified schemes; `setns` switches the current process to
//! that namespace.
//!
//! ## What we restrict
//!
//! Normal builds get: `file`, `memory`, `pipe`, `rand` (minimum viable set).
//! Fixed-output derivations (FODs) also get `net` for URL fetching.
//!
//! Excluded from ALL builds: `display`, `disk`, `irq`, `debug`,
//! `ptyd`, `audio`, `input`, `orbital`, etc.
//!
//! ## Limitations
//!
//! Namespace filtering is at the **scheme level**, not per-path within
//! a scheme. `file:` is either visible or not — we can't restrict it
//! to just `$out` and `$TMPDIR`. Per-path filtering would require a
//! proxy scheme daemon (future work).
//!
//! The `allowed_input_hashes` field in `SandboxConfig` is collected for
//! future use when per-hash `store:` filtering becomes possible. For
//! now, we don't include `store:` in the namespace — builders access
//! store paths through `file:/nix/store/` which is under `file:`.
//!
//! ## Call site
//!
//! `setup_build_namespace()` runs in the child process between `fork()`
//! and `exec()` (via `Command::pre_exec`). On failure, the caller in
//! `local_build.rs` falls back to unsandboxed execution.
//!
//! Feature-gated behind `#[cfg(target_os = "redox")]`.
//! On other platforms, all functions are no-ops.

use std::collections::HashSet;

use nix_compat::derivation::Derivation;

/// Information needed to set up a build sandbox.
#[derive(Debug)]
pub struct SandboxConfig {
    /// Store path hashes the builder is allowed to read.
    /// Collected for future per-hash filtering. Not enforced yet.
    pub allowed_input_hashes: HashSet<String>,
    /// Whether the builder needs network access (FOD).
    pub needs_network: bool,
    /// Output directory the builder writes to.
    pub output_dir: String,
    /// Temp directory for the build.
    pub tmp_dir: String,
}

/// Check if a derivation is a fixed-output derivation (FOD).
///
/// FODs have `outputHash` in their environment. They are allowed network
/// access because they fetch content by URL and verify it by hash.
pub fn is_fixed_output(drv: &Derivation) -> bool {
    drv.environment.contains_key("outputHash")
}

/// Build the set of allowed input store path hashes from a derivation.
///
/// Includes:
/// - All resolved outputs of input derivations
/// - All input sources (plain store path inputs)
///
/// Returns nixbase32 hashes (32 chars each).
pub fn collect_allowed_inputs(drv: &Derivation) -> HashSet<String> {
    let mut allowed = HashSet::new();

    // Input sources.
    for src in &drv.input_sources {
        allowed.insert(nix_compat::nixbase32::encode(src.digest()));
    }

    // Input derivation outputs.
    // We add the derivation path hashes here. The caller (local_build.rs)
    // resolves these to output hashes before passing to setup_build_namespace.
    for input_drv in drv.input_derivations.keys() {
        allowed.insert(nix_compat::nixbase32::encode(input_drv.digest()));
    }

    allowed
}

/// Build a SandboxConfig from a derivation.
pub fn config_from_derivation(
    drv: &Derivation,
    output_dir: &str,
    tmp_dir: &str,
) -> SandboxConfig {
    SandboxConfig {
        allowed_input_hashes: collect_allowed_inputs(drv),
        needs_network: is_fixed_output(drv),
        output_dir: output_dir.to_string(),
        tmp_dir: tmp_dir.to_string(),
    }
}

/// Schemes that every build needs — without these, processes can't
/// allocate memory, use pipes, or generate random numbers.
/// `rand` is needed because Rust's getrandom reads from `rand:` on
/// Redox (provided by randd). Without it, tempfile, hashing with
/// random seeds, and crypto operations all fail.
const REQUIRED_SCHEMES: &[&str] = &["file", "memory", "pipe", "rand"];

/// Additional schemes granted to fixed-output derivations.
const FOD_SCHEMES: &[&str] = &["net"];

/// Set up the build namespace for the current process.
///
/// On Redox: creates a new namespace via `mkns` containing only the
/// schemes the builder needs, then switches to it via `setns`.
/// On other platforms: no-op (returns Ok).
///
/// This MUST be called in the child process between fork() and exec().
/// The parent process is not affected.
///
/// # Scheme visibility
///
/// Normal builds:
///   - `file` — filesystem I/O ($out, $TMPDIR, /nix/store/*)
///   - `memory` — anonymous memory mappings (required by allocator)
///   - `pipe` — stdout/stderr/stdin pipes (required by shell/processes)
///   - `rand` — random number generation (required by getrandom/tempfile)
///
/// Fixed-output derivations (FODs) additionally get:
///   - `net` — network access for URL fetching
///
/// Everything else is excluded: `display`, `disk`, `irq`, `debug`,
/// `ptyd`, `audio`, `input`, `orbital`, etc.
pub fn setup_build_namespace(config: &SandboxConfig) -> Result<(), SandboxError> {
    #[cfg(target_os = "redox")]
    {
        setup_build_namespace_redox(config)
    }

    #[cfg(not(target_os = "redox"))]
    {
        let _ = config;
        Ok(())
    }
}

#[cfg(target_os = "redox")]
fn setup_build_namespace_redox(config: &SandboxConfig) -> Result<(), SandboxError> {
    use ioslice::IoSlice;

    // Build the list of schemes for this build's namespace.
    let mut scheme_names: Vec<&[u8]> = REQUIRED_SCHEMES
        .iter()
        .map(|s| s.as_bytes())
        .collect();

    if config.needs_network {
        for s in FOD_SCHEMES {
            scheme_names.push(s.as_bytes());
        }
    }

    let io_slices: Vec<IoSlice> = scheme_names
        .iter()
        .map(|name| IoSlice::new(name))
        .collect();

    // Create a new namespace containing only the listed schemes.
    // This forks the current namespace fd, keeping only the specified
    // scheme registrations.
    let ns_fd = libredox::call::mkns(&io_slices).map_err(|e| {
        if e.errno() == libredox::errno::ENOSYS {
            SandboxError::Unavailable
        } else {
            SandboxError::SyscallFailed(format!("mkns: {e}"))
        }
    })?;

    // Switch the current process to the restricted namespace.
    // After this, any open() to a scheme not in the namespace will fail
    // with ENOENT. Already-open fds are unaffected.
    libredox::call::setns(ns_fd).map_err(|e| {
        SandboxError::SyscallFailed(format!("setns: {e}"))
    })?;

    Ok(())
}

/// Errors from sandbox setup.
#[derive(Debug)]
pub enum SandboxError {
    /// The namespace syscall is not available on this kernel.
    Unavailable,
    /// The syscall failed with an unexpected error.
    SyscallFailed(String),
}

impl std::fmt::Display for SandboxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(f, "namespace sandboxing unavailable on this kernel"),
            Self::SyscallFailed(msg) => write!(f, "sandbox syscall failed: {msg}"),
        }
    }
}

impl std::error::Error for SandboxError {}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use nix_compat::derivation::Derivation;

    fn make_drv() -> Derivation {
        let mut drv = Derivation::default();
        drv.builder = "/bin/sh".to_string();
        drv.system = "x86_64-linux".to_string();
        drv
    }

    #[test]
    fn is_fixed_output_false() {
        let drv = make_drv();
        assert!(!is_fixed_output(&drv));
    }

    #[test]
    fn is_fixed_output_true() {
        let mut drv = make_drv();
        drv.environment
            .insert("outputHash".to_string(), "sha256-abc123".into());
        assert!(is_fixed_output(&drv));
    }

    #[test]
    fn collect_inputs_empty() {
        let drv = make_drv();
        let inputs = collect_allowed_inputs(&drv);
        assert!(inputs.is_empty());
    }

    #[test]
    fn collect_inputs_with_sources() {
        use nix_compat::store_path::StorePath;

        let mut drv = make_drv();
        let src = StorePath::<String>::from_absolute_path(
            b"/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-src",
        )
        .unwrap();
        drv.input_sources.insert(src);

        let inputs = collect_allowed_inputs(&drv);
        assert_eq!(inputs.len(), 1);
        assert!(inputs.contains("1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r"));
    }

    #[test]
    fn config_from_derivation_normal() {
        let drv = make_drv();
        let config = config_from_derivation(&drv, "/nix/store/out", "/tmp/build");

        assert!(!config.needs_network);
        assert_eq!(config.output_dir, "/nix/store/out");
        assert_eq!(config.tmp_dir, "/tmp/build");
    }

    #[test]
    fn config_from_derivation_fod() {
        let mut drv = make_drv();
        drv.environment
            .insert("outputHash".to_string(), "sha256-abc".into());
        let config = config_from_derivation(&drv, "/nix/store/out", "/tmp/build");

        assert!(config.needs_network);
    }

    #[test]
    fn required_schemes_has_essentials() {
        assert!(REQUIRED_SCHEMES.contains(&"file"));
        assert!(REQUIRED_SCHEMES.contains(&"memory"));
        assert!(REQUIRED_SCHEMES.contains(&"pipe"));
        assert!(REQUIRED_SCHEMES.contains(&"rand"));
    }

    #[test]
    fn fod_schemes_has_net() {
        assert!(FOD_SCHEMES.contains(&"net"));
    }

    #[test]
    fn setup_namespace_noop_on_non_redox() {
        // On non-Redox platforms (Linux, macOS), setup is always a no-op.
        let config = SandboxConfig {
            allowed_input_hashes: HashSet::new(),
            needs_network: false,
            output_dir: "/out".to_string(),
            tmp_dir: "/tmp".to_string(),
        };

        let result = setup_build_namespace(&config);
        assert!(result.is_ok());
    }

    #[test]
    fn normal_build_excludes_net() {
        let drv = make_drv();
        let config = config_from_derivation(&drv, "/nix/store/out", "/tmp/build");
        assert!(!config.needs_network);
    }

    #[test]
    fn fod_build_includes_net() {
        let mut drv = make_drv();
        drv.environment
            .insert("outputHash".to_string(), "sha256-abc".into());
        let config = config_from_derivation(&drv, "/nix/store/out", "/tmp/build");
        assert!(config.needs_network);
    }
}
