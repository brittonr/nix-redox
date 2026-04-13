//! Build sandboxing for Redox OS.
//!
//! Restricts builder processes using Redox's namespace system
//! (`mkns`/`setns`) to control which schemes a builder can access.
//! Blocks `display:`, `disk:`, `irq:`, `audio:`, etc. while keeping
//! `file:` (full redoxfs access), `memory:`, `pipe:`, `rand:`, and
//! other essential schemes.
//!
//! ## Current sandbox mode: per-path proxy by default
//!
//! The default sandbox creates a child namespace without the real
//! `file:` scheme, then registers the build proxy as `file:` in that
//! namespace. Builders can only read declared inputs and can only write
//! to `$out` and `$TMPDIR`. FOD builds also get `net:` for network access.
//!
//! The proxy's scheme thread does not perform real filesystem I/O
//! directly. Instead it forwards all redoxfs/device operations to a
//! dedicated worker thread that owns the pre-opened root/device handles.
//!
//! If proxy setup fails, snix falls back to the scheme-only sandbox.
//! Use `--no-sandbox` or `SNIX_NO_SANDBOX=1` to disable sandboxing
//! entirely.
//!
//! ## Sandbox modes summary
//!
//! | Mode | file: scheme | Filesystem access | Status |
//! |------|-------------|-------------------|--------|
//! | Scheme-only | real redoxfs | everything | Fallback |
//! | Per-path proxy | proxy daemon | allow-list only | **Active default** |
//! | Unsandboxed | real redoxfs | everything | `--no-sandbox` / config |
//!
//! ## Call sites
//!
//! - `setup_proxy_namespace()` — creates namespace + starts proxy
//!   (active path)
//! - `setup_build_namespace()` — creates restricted namespace with the
//!   real `file:` scheme still visible (fallback path)
//!
//! ## Scheme list
//!
//! Normal builds: `file`, `memory`, `pipe`, `rand`, `null`, `zero`,
//! `proc`, `sys`, `time`, `debug`, `shm`.
//!
//! FOD builds additionally get: `net`.
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
pub fn config_from_derivation(drv: &Derivation, output_dir: &str, tmp_dir: &str) -> SandboxConfig {
    SandboxConfig {
        allowed_input_hashes: collect_allowed_inputs(drv),
        needs_network: is_fixed_output(drv),
        output_dir: output_dir.to_string(),
        tmp_dir: tmp_dir.to_string(),
    }
}

/// Schemes included in every build namespace.
///
/// Used by `setup_build_namespace()` to create the restricted
/// namespace. Includes `file:` for full filesystem access.
/// - `file` — filesystem I/O ($out, $TMPDIR, /nix/store/*)
/// - `memory` — anonymous memory mappings (required by allocator)
/// - `pipe` — stdout/stderr/stdin pipes
/// - `rand` — random number generation (getrandom reads `rand:`)
/// - `null` — /dev/null (builders redirect stderr there constantly)
/// - `zero` — /dev/zero (occasionally used for zeroed reads)
/// - `proc` — process fd (needed by relibc for PID, etc.)
/// - `sys` — system info (uname, cpu count)
/// - `time` — clock_gettime
/// - `debug` — serial console (stderr output)
/// - `shm` — shared memory (needed by some allocators)
const REQUIRED_SCHEMES: &[&str] = &[
    "file", "memory", "pipe", "rand", "null", "zero", "proc", "sys", "time", "debug", "shm",
];

/// Schemes for proxy-based sandbox (NO `file` — proxy registers as `file`).
///
/// Used by `setup_proxy_namespace()`. The proxy daemon registers itself
/// as `file` in this namespace, giving builders filtered filesystem access.
#[cfg(target_os = "redox")]
const PROXY_REQUIRED_SCHEMES: &[&str] = &[
    "memory", "pipe", "rand", "null", "zero",
    // relibc init needs these — without them, exec'd binaries crash
    // during relibc_start_v1 before reaching main().
    "proc",  // process fd (proc_fd) — needed by relibc for PID, etc.
    "sys",   // system info (uname, cpu count)
    "time",  // clock_gettime
    "debug", // serial console (stderr output)
    "shm",   // shared memory (needed by some allocators)
];

/// Additional schemes granted to fixed-output derivations.
const FOD_SCHEMES: &[&str] = &["net"];

/// Set up the build namespace for the current process.
///
/// On Redox: creates a new namespace via `mkns` containing only the
/// schemes the builder needs (see `REQUIRED_SCHEMES`), then switches
/// to it via `setns`.
/// On other platforms: no-op (returns Ok).
///
/// This MUST be called in the child process between fork() and exec().
/// The parent process is not affected.
///
/// This is the fallback sandbox path. It includes the real `file:`
/// scheme, giving the builder full filesystem access while blocking
/// sensitive schemes like `display:`, `disk:`, `irq:`, `audio:`,
/// `input:`, `orbital:`, `ptyd:`, etc.
///
/// FOD builds additionally get `net:` for URL fetching.
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
    let mut scheme_names: Vec<&[u8]> = REQUIRED_SCHEMES.iter().map(|s| s.as_bytes()).collect();

    if config.needs_network {
        for s in FOD_SCHEMES {
            scheme_names.push(s.as_bytes());
        }
    }

    let io_slices: Vec<IoSlice> = scheme_names.iter().map(|name| IoSlice::new(name)).collect();

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
    libredox::call::setns(ns_fd).map_err(|e| SandboxError::SyscallFailed(format!("setns: {e}")))?;

    Ok(())
}

/// Create a child namespace with a per-path filesystem proxy.
///
/// This is the enhanced sandbox: instead of including `file:` in the
/// child namespace (which grants access to the entire filesystem), we
/// exclude `file:` and register a proxy daemon as `file:` in the child
/// namespace. The proxy filters I/O against the allow-list.
///
/// Returns `(child_ns_fd, BuildFsProxy)` on success. The caller must:
/// 1. Use `child_ns_fd` in `pre_exec` (child calls `setns(child_ns_fd)`)
/// 2. Keep the `BuildFsProxy` alive until the builder exits
/// 3. Call `proxy.shutdown()` after the builder exits
///
/// On failure, the caller should fall back to `setup_build_namespace()`
/// which includes the real `file:` scheme (less restrictive but functional).
#[cfg(target_os = "redox")]
pub fn setup_proxy_namespace(
    config: &SandboxConfig,
    allow_list: crate::build_proxy::AllowList,
) -> Result<(usize, crate::build_proxy::BuildFsProxy), SandboxError> {
    use ioslice::IoSlice;

    // Build the scheme list WITHOUT file:.
    // The proxy will register as file: in this namespace.
    let mut scheme_names: Vec<&[u8]> = PROXY_REQUIRED_SCHEMES
        .iter()
        .map(|s| s.as_bytes())
        .collect();

    if config.needs_network {
        for s in FOD_SCHEMES {
            scheme_names.push(s.as_bytes());
        }
    }

    let io_slices: Vec<IoSlice> = scheme_names.iter().map(|name| IoSlice::new(name)).collect();

    // Create the child namespace (no file: scheme).
    let child_ns_fd = libredox::call::mkns(&io_slices).map_err(|e| {
        if e.errno() == libredox::errno::ENOSYS {
            SandboxError::Unavailable
        } else {
            SandboxError::SyscallFailed(format!("mkns (proxy): {e}"))
        }
    })?;

    // Start the proxy and register it as file: in the child namespace.
    let proxy = crate::build_proxy::BuildFsProxy::start(child_ns_fd, allow_list)
        .map_err(|e| SandboxError::SyscallFailed(format!("proxy start: {e}")))?;

    Ok((child_ns_fd, proxy))
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

    // ── Proxy scheme list tests ────────────────────────────────────────

    #[test]
    fn required_schemes_includes_file() {
        // Legacy fallback list includes file: for full access.
        assert!(REQUIRED_SCHEMES.contains(&"file"));
        assert!(REQUIRED_SCHEMES.contains(&"memory"));
        assert!(REQUIRED_SCHEMES.contains(&"pipe"));
        assert!(REQUIRED_SCHEMES.contains(&"rand"));
        assert!(REQUIRED_SCHEMES.contains(&"null"));
        assert!(REQUIRED_SCHEMES.contains(&"zero"));
    }

    #[cfg(target_os = "redox")]
    #[test]
    fn proxy_schemes_excludes_file() {
        // Proxy list does NOT include file: — the proxy registers as file:.
        assert!(!PROXY_REQUIRED_SCHEMES.contains(&"file"));
        assert!(PROXY_REQUIRED_SCHEMES.contains(&"memory"));
        assert!(PROXY_REQUIRED_SCHEMES.contains(&"pipe"));
        assert!(PROXY_REQUIRED_SCHEMES.contains(&"rand"));
        assert!(PROXY_REQUIRED_SCHEMES.contains(&"null"));
        assert!(PROXY_REQUIRED_SCHEMES.contains(&"zero"));
    }

    #[cfg(target_os = "redox")]
    #[test]
    fn proxy_schemes_is_required_minus_file() {
        // PROXY_REQUIRED_SCHEMES should be exactly REQUIRED_SCHEMES minus "file".
        let required: HashSet<&str> = REQUIRED_SCHEMES.iter().copied().collect();
        let proxy: HashSet<&str> = PROXY_REQUIRED_SCHEMES.iter().copied().collect();

        let diff: HashSet<&str> = required.difference(&proxy).copied().collect();
        assert_eq!(diff.len(), 1);
        assert!(diff.contains("file"));

        let extra: HashSet<&str> = proxy.difference(&required).copied().collect();
        assert!(
            extra.is_empty(),
            "proxy has schemes not in required: {extra:?}"
        );
    }
}
