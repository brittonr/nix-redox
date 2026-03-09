//! Namespace sandboxing for Redox build isolation.
//!
//! Restricts a builder process's scheme namespace so it can only access:
//! - `file:` — for the output directory ($out) and temp ($TMPDIR)
//! - `store:` — for reading declared input store paths
//! - `net:` — only for fixed-output derivations (FODs) that need network
//!
//! Uses Redox's native `setrens` / namespace syscalls to restrict which
//! schemes the child process can see. This is equivalent to Linux
//! namespaces + seccomp but with a single mechanism.
//!
//! Feature-gated behind `#[cfg(target_os = "redox")]`.
//! On other platforms, all functions are no-ops.

use std::collections::HashSet;

use nix_compat::derivation::Derivation;

/// Information needed to set up a build sandbox.
#[derive(Debug)]
pub struct SandboxConfig {
    /// Store path hashes the builder is allowed to read.
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
/// FODs have `outputHash`, `outputHashAlgo`, and/or `outputHashMode`
/// in their environment. They are allowed network access because they
/// fetch content by URL and verify it by hash.
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
    // Note: we add the derivation path hashes here. In practice,
    // the namespace restriction would filter by resolved output
    // hashes, but we don't have access to KnownPaths in this module.
    // The caller (local_build.rs) should resolve these before calling.
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

/// Set up the build namespace for the current process.
///
/// On Redox: will call `setrens()` to restrict scheme visibility once
/// the `libredox` crate is added as a target-specific dependency.
/// On other platforms: no-op (returns Ok).
///
/// This MUST be called in the child process between fork() and exec().
/// The parent process is not affected.
///
/// Redox kernel namespace mechanism (for when this is wired up):
///   - `setrens(name_ns, scheme_ns)` sets the process's namespace
///   - `name_ns` controls which named resources are visible
///   - `scheme_ns` controls which schemes are visible
///   - 0 means "empty namespace" (nothing visible)
///
/// For build sandboxing, we want:
///   - `file:` visible (restricted to output + tmp dirs)
///   - `store:` visible (restricted to allowed input hashes)
///   - `net:` visible only for FODs
///
/// Implementation will call `libredox::call::setrens(0, 0)` and fall
/// back on `ENOSYS`/`EPERM`. Granular per-scheme filtering depends on
/// kernel support — initially we'd open allowed scheme fds BEFORE
/// `setrens()`, then pass them to the builder via inherited fds.
pub fn setup_build_namespace(_config: &SandboxConfig) -> Result<(), SandboxError> {
    // TODO: On Redox, call libredox::call::setrens(0, 0) to enter a
    // null namespace. Requires adding `libredox` as a [target.'cfg(target_os = "redox")'.dependencies]
    // in Cargo.toml. Until then, builds run unsandboxed (current behavior).
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
            Self::Unavailable => write!(f, "namespace sandboxing unavailable"),
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
        drv.environment.insert(
            "outputHash".to_string(),
            "sha256-abc123".into(),
        );
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
        drv.environment.insert(
            "outputHash".to_string(),
            "sha256-abc".into(),
        );
        let config = config_from_derivation(&drv, "/nix/store/out", "/tmp/build");

        assert!(config.needs_network);
    }

    #[test]
    fn setup_namespace_noop_on_linux() {
        let config = SandboxConfig {
            allowed_input_hashes: HashSet::new(),
            needs_network: false,
            output_dir: "/out".to_string(),
            tmp_dir: "/tmp".to_string(),
        };

        // On Linux, this is a no-op.
        let result = setup_build_namespace(&config);
        assert!(result.is_ok());
    }
}
