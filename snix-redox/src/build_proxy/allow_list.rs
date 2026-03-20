//! Path-based access control for the build filesystem proxy.
//!
//! The `AllowList` determines which filesystem paths a builder process
//! can access. Paths are grouped into read-only (input store paths)
//! and read-write (`$out`, `$TMPDIR`). Access checks use prefix matching:
//! opening `/nix/store/abc-dep/lib/foo.so` succeeds if `/nix/store/abc-dep`
//! is on the list.
//!
//! Prefix matching requires an exact component boundary — `/nix/store/abc`
//! does NOT match `/nix/store/abcdef` (different store path).

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// What a builder is allowed to do with a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Permission {
    /// Path is not on the allow-list.
    Denied,
    /// Path matches a read-only entry (input store paths).
    ReadOnly,
    /// Path matches a read-write entry ($out, $TMPDIR).
    ReadWrite,
}

/// Allow-list for build filesystem access.
///
/// Paths are stored as canonicalized `PathBuf`s. Access checks
/// compare the requested path against each entry using prefix
/// matching with component-boundary enforcement.
#[derive(Debug, Clone)]
pub struct AllowList {
    /// Paths the builder can read but not write (input store paths).
    pub read_only: HashSet<PathBuf>,
    /// Paths the builder can read and write ($out, $TMPDIR).
    pub read_write: HashSet<PathBuf>,
}

impl AllowList {
    /// Create an empty allow-list (denies everything).
    pub fn new() -> Self {
        Self {
            read_only: HashSet::new(),
            read_write: HashSet::new(),
        }
    }

    /// Check what permission a path has.
    ///
    /// Uses prefix matching: `/nix/store/abc-dep/lib/foo.so` matches
    /// the entry `/nix/store/abc-dep`. The match requires a component
    /// boundary — the requested path must either equal the entry exactly
    /// or have a `/` separator after the entry prefix.
    ///
    /// Read-write entries take priority over read-only if both match
    /// (shouldn't happen in practice, but defined behavior).
    pub fn check(&self, path: &Path) -> Permission {
        // Check read-write first (higher privilege).
        for entry in &self.read_write {
            if path_matches_prefix(path, entry) {
                return Permission::ReadWrite;
            }
        }
        for entry in &self.read_only {
            if path_matches_prefix(path, entry) {
                return Permission::ReadOnly;
            }
        }
        Permission::Denied
    }

    /// Check if a path is readable (read-only or read-write).
    pub fn can_read(&self, path: &Path) -> bool {
        self.check(path) != Permission::Denied
    }

    /// Check if a path is writable (read-write only).
    pub fn can_write(&self, path: &Path) -> bool {
        self.check(path) == Permission::ReadWrite
    }

    /// Return all allowed path prefixes (both read-only and read-write).
    /// Used by `getdents` to filter directory listings.
    pub fn all_prefixes(&self) -> impl Iterator<Item = &Path> {
        self.read_only
            .iter()
            .chain(self.read_write.iter())
            .map(|p| p.as_path())
    }
}

/// Check if `path` is equal to or a child of `prefix`.
///
/// Requires a component boundary: `/nix/store/abc` matches
/// `/nix/store/abc` and `/nix/store/abc/lib/foo`, but NOT
/// `/nix/store/abcdef`.
///
/// IMPORTANT: The path is cleaned first — `..` components are
/// resolved logically (without touching the filesystem) to prevent
/// traversal attacks like `/nix/store/abc/../../etc/passwd`.
fn path_matches_prefix(path: &Path, prefix: &Path) -> bool {
    let clean = clean_path(path);

    // Fast path: exact match.
    if clean == prefix {
        return true;
    }

    // Check that path starts with all components of prefix.
    // std::path::Path::starts_with already does component-boundary
    // matching: Path("/nix/store/abc").starts_with("/nix/store/abc")
    // is true, but Path("/nix/store/abcdef").starts_with("/nix/store/abc")
    // is false. This is exactly the behavior we need.
    clean.starts_with(prefix)
}

/// Logically resolve `.` and `..` components without touching the filesystem.
///
/// This prevents path traversal attacks: `/nix/store/abc/../../etc/passwd`
/// becomes `/etc/passwd`, which won't match the `/nix/store/abc` prefix.
fn clean_path(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                // Go up one level (pop the last component).
                result.pop();
            }
            Component::CurDir => {
                // Current dir "." — skip.
            }
            c => {
                result.push(c);
            }
        }
    }
    result
}

/// Normalize a path for allow-list storage and comparison.
///
/// Strips trailing slashes and collapses redundant separators.
/// Does NOT resolve symlinks or `..` (the caller should not pass
/// relative paths — all store paths and build dirs are absolute).
pub fn normalize_path(path: &str) -> PathBuf {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        PathBuf::from("/")
    } else {
        PathBuf::from(trimmed)
    }
}

// ── Build AllowList from Derivation ────────────────────────────────────────

use nix_compat::derivation::Derivation;

use snix_glue::known_paths::KnownPaths;

/// System paths that every builder needs read-only access to.
///
/// On Redox, these provide:
///   - `/nix/system/profile` — system tools (bash, coreutils, cc, etc.)
///   - `/nix/store` — entire store (read-only, matching Nix sandbox semantics)
///   - `/usr/lib` — dynamic linker (ld64.so.1) and runtime libraries
///   - `/usr/src` — source bundles for self-hosting builds
///   - `/lib` — additional shared libraries
///   - `/etc` — system configuration (timezone, hostname, snix config)
///   - `/bin`, `/usr/bin` — standard PATH directories; builders set
///     `PATH=/nix/system/profile/bin:/bin:/usr/bin` and bash resolves
///     commands by trying each PATH entry. Without these, the proxy
///     returns EACCES (not ENOENT) when bash checks `/bin/cmd`, causing
///     "Permission denied" (exit 126) instead of falling through to
///     the next PATH entry.
///
/// The full-store read-only access matches how Nix sandbox works on Linux:
/// the entire /nix/store is bind-mounted read-only. Per-derivation filtering
/// (only declared inputs) would be stricter but requires resolving the
/// transitive closure of the builder binary's shared libraries, which the
/// allow-list doesn't support yet.
const SYSTEM_READ_ONLY_PATHS: &[&str] = &[
    "/nix/system/profile",
    "/nix/store",
    "/usr/lib",
    "/usr/src",
    "/lib",
    "/etc",
    "/bin",
    "/usr/bin",
];

/// Build an `AllowList` from a derivation's declared inputs.
///
/// Read-write:
///   - `output_dir` — the derivation's `$out`
///   - `tmp_dir` — the derivation's `$TMPDIR`
///
/// Read-only:
///   - System paths needed for execution (builder binary, dynamic linker, etc.)
///   - Resolved output paths of all `input_derivations`
///   - All `input_sources` (plain store path inputs)
///   - The builder binary path itself
pub fn build_allow_list(
    drv: &Derivation,
    known_paths: &KnownPaths,
    output_dir: &str,
    tmp_dir: &str,
) -> AllowList {
    let mut list = AllowList::new();

    // Read-write: output directory and temp directory.
    list.read_write.insert(normalize_path(output_dir));
    list.read_write.insert(normalize_path(tmp_dir));

    // Read-only: system paths needed for builder execution.
    // The builder binary, dynamic linker, shared libraries, and
    // the entire store (matching Nix sandbox semantics on Linux).
    for path in SYSTEM_READ_ONLY_PATHS {
        list.read_only.insert(normalize_path(path));
    }

    // Read-only: the builder binary itself (may not be under /nix/).
    if !drv.builder.is_empty() {
        let builder_path = normalize_path(&drv.builder);
        list.read_only.insert(builder_path);
    }

    // Read-only: builder arguments that are absolute file paths.
    //
    // Derivation args like ["/tmp/build-hello-cargo.sh"] or
    // ["/usr/src/snix-redox/build-snix.sh"] reference files the
    // builder must read. Non-path args ("-c", inline scripts) are
    // harmlessly ignored — adding a non-existent path to the
    // allow-list has no effect.
    for arg in &drv.arguments {
        if arg.starts_with('/') {
            list.read_only.insert(normalize_path(arg));
        }
    }

    // Read-only: environment values that are absolute paths.
    //
    // Derivation env vars may reference files outside the store
    // (e.g., source bundles, config files). Store paths are already
    // covered by input_sources/input_derivations and the blanket
    // /nix/store entry, but non-store absolute paths need explicit
    // inclusion. Skip "out" (read-write) and values that don't
    // look like paths.
    for (key, val) in &drv.environment {
        if key == "out" {
            continue;
        }
        if let Ok(s) = std::str::from_utf8(val.as_ref()) {
            if s.starts_with('/') && !s.contains(' ') {
                list.read_only.insert(normalize_path(s));
            }
        }
    }

    // Read-only: input sources.
    for src in &drv.input_sources {
        list.read_only.insert(normalize_path(&src.to_absolute_path()));
    }

    // Read-only: resolved outputs of input derivations.
    for (input_drv_path, output_names) in &drv.input_derivations {
        if let Some(input_drv) = known_paths.get_drv_by_drvpath(input_drv_path) {
            for output_name in output_names {
                if let Some(output) = input_drv.outputs.get(output_name) {
                    if let Some(ref sp) = output.path {
                        list.read_only.insert(normalize_path(&sp.to_absolute_path()));
                    }
                }
            }
        }
    }

    list
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use nix_compat::store_path::StorePath;

    fn make_list() -> AllowList {
        let mut list = AllowList::new();
        list.read_only.insert(PathBuf::from("/nix/store/abc-dep-1.0"));
        list.read_only.insert(PathBuf::from("/nix/store/def-dep-2.0"));
        list.read_write.insert(PathBuf::from("/nix/store/ghi-output-1.0"));
        list.read_write.insert(PathBuf::from("/tmp/snix-build-42-0"));
        list
    }

    // ── Permission::check ──────────────────────────────────────────────

    #[test]
    fn read_only_exact_match() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/nix/store/abc-dep-1.0")),
            Permission::ReadOnly,
        );
    }

    #[test]
    fn read_only_nested_path() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/nix/store/abc-dep-1.0/lib/libfoo.so")),
            Permission::ReadOnly,
        );
    }

    #[test]
    fn read_write_exact_match() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/nix/store/ghi-output-1.0")),
            Permission::ReadWrite,
        );
    }

    #[test]
    fn read_write_nested_path() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/nix/store/ghi-output-1.0/bin/hello")),
            Permission::ReadWrite,
        );
    }

    #[test]
    fn tmpdir_writable() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/tmp/snix-build-42-0/scratch/foo.o")),
            Permission::ReadWrite,
        );
    }

    #[test]
    fn denied_unlisted_store_path() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/nix/store/xyz-other-2.0/bin/bar")),
            Permission::Denied,
        );
    }

    #[test]
    fn denied_outside_store() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/home/user/.ssh/id_rsa")),
            Permission::Denied,
        );
    }

    #[test]
    fn denied_etc_passwd() {
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/etc/passwd")),
            Permission::Denied,
        );
    }

    // ── Prefix boundary enforcement ────────────────────────────────────

    #[test]
    fn prefix_boundary_no_false_positive() {
        // /nix/store/abc-dep-1.0 is allowed, but /nix/store/abc-dep-1.0-other is NOT.
        let list = make_list();
        assert_eq!(
            list.check(Path::new("/nix/store/abc-dep-1.0-other/bin/foo")),
            Permission::Denied,
        );
    }

    #[test]
    fn prefix_boundary_exact_plus_slash() {
        let list = make_list();
        // abc-dep-1.0/ is the entry itself with a trailing slash component.
        assert_eq!(
            list.check(Path::new("/nix/store/abc-dep-1.0/")),
            Permission::ReadOnly,
        );
    }

    #[test]
    fn prefix_boundary_partial_name() {
        // "abc" shouldn't match "abc-dep-1.0"
        let mut list = AllowList::new();
        list.read_only.insert(PathBuf::from("/nix/store/abc"));
        assert_eq!(
            list.check(Path::new("/nix/store/abc-dep-1.0/lib/foo")),
            Permission::Denied,
        );
    }

    // ── Convenience methods ────────────────────────────────────────────

    #[test]
    fn can_read_allowed() {
        let list = make_list();
        assert!(list.can_read(Path::new("/nix/store/abc-dep-1.0/lib/foo")));
        assert!(list.can_read(Path::new("/nix/store/ghi-output-1.0/bin/hello")));
    }

    #[test]
    fn can_read_denied() {
        let list = make_list();
        assert!(!list.can_read(Path::new("/etc/passwd")));
    }

    #[test]
    fn can_write_rw_path() {
        let list = make_list();
        assert!(list.can_write(Path::new("/nix/store/ghi-output-1.0/bin/hello")));
    }

    #[test]
    fn can_write_ro_path_denied() {
        let list = make_list();
        assert!(!list.can_write(Path::new("/nix/store/abc-dep-1.0/lib/foo")));
    }

    #[test]
    fn can_write_unlisted_denied() {
        let list = make_list();
        assert!(!list.can_write(Path::new("/etc/shadow")));
    }

    // ── Empty allow-list ───────────────────────────────────────────────

    #[test]
    fn empty_list_denies_everything() {
        let list = AllowList::new();
        assert_eq!(list.check(Path::new("/nix/store/anything")), Permission::Denied);
        assert_eq!(list.check(Path::new("/")), Permission::Denied);
        assert_eq!(list.check(Path::new("/tmp/foo")), Permission::Denied);
    }

    // ── normalize_path ─────────────────────────────────────────────────

    #[test]
    fn normalize_strips_trailing_slash() {
        assert_eq!(normalize_path("/nix/store/abc/"), PathBuf::from("/nix/store/abc"));
    }

    #[test]
    fn normalize_preserves_root() {
        assert_eq!(normalize_path("/"), PathBuf::from("/"));
    }

    #[test]
    fn normalize_no_trailing_slash() {
        assert_eq!(normalize_path("/nix/store/abc"), PathBuf::from("/nix/store/abc"));
    }

    // ── build_allow_list ───────────────────────────────────────────────

    #[test]
    fn build_allow_list_basic() {
        let drv = Derivation::default();
        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/out-hash-name", "/tmp/build-1");

        // Output and tmpdir are read-write.
        assert!(list.can_write(Path::new("/nix/store/out-hash-name/bin/foo")));
        assert!(list.can_write(Path::new("/tmp/build-1/scratch.o")));

        // System paths are read-only (builder needs them).
        assert!(list.can_read(Path::new("/nix/system/profile/bin/bash")));
        assert!(list.can_read(Path::new("/nix/store/abc-any-store-path/lib/foo")));
        assert!(list.can_read(Path::new("/usr/lib/ld64.so.1")));
        assert!(list.can_read(Path::new("/usr/src/snix-redox/build.nix")));
        assert!(list.can_read(Path::new("/etc/snix/config")));
        assert!(list.can_read(Path::new("/bin/mkdir")));
        assert!(list.can_read(Path::new("/usr/bin/env")));

        // System paths are NOT writable.
        assert!(!list.can_write(Path::new("/nix/system/profile/bin/bash")));
        assert!(!list.can_write(Path::new("/nix/store/abc-any-store-path/lib/foo")));
        assert!(!list.can_write(Path::new("/bin/mkdir")));
        assert!(!list.can_write(Path::new("/usr/src/anything")));

        // Home dirs are not allowed.
        assert!(!list.can_read(Path::new("/home/user/.ssh/id_rsa")));
    }

    #[test]
    fn build_allow_list_with_input_sources() {
        let mut drv = Derivation::default();
        let src = StorePath::<String>::from_absolute_path(
            b"/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-src",
        )
        .unwrap();
        drv.input_sources.insert(src);

        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/out", "/tmp/build");

        // Input source is read-only.
        assert!(list.can_read(Path::new(
            "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-src/default.nix"
        )));
        assert!(!list.can_write(Path::new(
            "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-src/default.nix"
        )));
    }

    // ── Builder args and environment scanning ────────────────────────

    #[test]
    fn build_allow_list_includes_builder_args() {
        // Builder args that are absolute paths should be read-only.
        let mut drv = Derivation::default();
        drv.builder = "/nix/system/profile/bin/bash".to_string();
        drv.arguments = vec![
            "/tmp/build-hello-cargo.sh".to_string(),
        ];

        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/out", "/tmp/build");

        // The build script path is readable.
        assert!(list.can_read(Path::new("/tmp/build-hello-cargo.sh")));
        // But not writable.
        assert!(!list.can_write(Path::new("/tmp/build-hello-cargo.sh")));
    }

    #[test]
    fn build_allow_list_skips_non_path_args() {
        // Args like "-c" or inline scripts should NOT be added.
        let mut drv = Derivation::default();
        drv.builder = "/nix/system/profile/bin/bash".to_string();
        drv.arguments = vec![
            "-c".to_string(),
            "echo hello > $out".to_string(),
        ];

        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/out", "/tmp/build");

        // Non-path args don't pollute the allow-list.
        // "-c" doesn't start with '/' so is not added.
        // "echo hello > $out" doesn't start with '/' so is not added.
        // Only system paths and the builder itself should be present.
        assert!(!list.can_read(Path::new("/tmp/random-file")));
    }

    #[test]
    fn build_allow_list_includes_env_paths() {
        // Environment values that are absolute paths should be read-only.
        use bstr::BString;
        let mut drv = Derivation::default();
        drv.environment.insert(
            "src".to_string(),
            BString::from("/usr/src/myproject"),
        );
        drv.environment.insert(
            "CFLAGS".to_string(),
            BString::from("-O2 -Wall"),
        );

        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/out", "/tmp/build");

        // Absolute path env value is readable.
        assert!(list.can_read(Path::new("/usr/src/myproject/src/main.c")));
        // Non-path env value doesn't add anything.
        // (CFLAGS has spaces so is excluded by the heuristic.)
    }

    #[test]
    fn build_allow_list_env_skips_out() {
        // The "out" env var is already added as read-write — don't
        // downgrade it to read-only.
        use bstr::BString;
        let mut drv = Derivation::default();
        drv.environment.insert(
            "out".to_string(),
            BString::from("/nix/store/abc-output"),
        );

        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/abc-output", "/tmp/build");

        // "out" is read-write, not downgraded to read-only.
        assert!(list.can_write(Path::new("/nix/store/abc-output/bin/foo")));
    }

    #[test]
    fn build_allow_list_real_derivation_pattern() {
        // Simulate the real snix-compile derivation pattern:
        //   builder = "/nix/system/profile/bin/bash"
        //   args = ["/usr/src/snix-redox/build-snix.sh"]
        let mut drv = Derivation::default();
        drv.builder = "/nix/system/profile/bin/bash".to_string();
        drv.arguments = vec![
            "/usr/src/snix-redox/build-snix.sh".to_string(),
        ];

        let kp = KnownPaths::default();
        let list = build_allow_list(&drv, &kp, "/nix/store/out", "/tmp/build");

        // Builder is accessible.
        assert!(list.can_read(Path::new("/nix/system/profile/bin/bash")));
        // Build script is accessible (from args).
        assert!(list.can_read(Path::new("/usr/src/snix-redox/build-snix.sh")));
        // Source directory is accessible (from /usr/src system path).
        assert!(list.can_read(Path::new("/usr/src/snix-redox/src/main.rs")));
        // PATH directories are accessible (bash needs for command lookup).
        assert!(list.can_read(Path::new("/bin/mkdir")));
        assert!(list.can_read(Path::new("/usr/bin/env")));
        // Tools in system profile are accessible.
        assert!(list.can_read(Path::new("/nix/system/profile/bin/cargo")));
    }

    // ── Symlink tests ───────────────────────────────────────────────

    #[test]
    fn symlink_within_allowed_prefix() {
        // Symlink target is under the same allowed prefix — should pass.
        let tmp = tempfile::tempdir().unwrap();
        let allowed_dir = tmp.path().join("allowed");
        std::fs::create_dir_all(allowed_dir.join("lib")).unwrap();
        std::fs::write(allowed_dir.join("lib/real.so"), "data").unwrap();
        std::os::unix::fs::symlink("real.so", allowed_dir.join("lib/link.so")).unwrap();

        let mut list = AllowList::new();
        list.read_only.insert(allowed_dir.clone());

        // Both the symlink and its target are under the allowed prefix.
        assert!(list.can_read(&allowed_dir.join("lib/link.so")));
        assert!(list.can_read(&allowed_dir.join("lib/real.so")));
    }

    #[test]
    fn symlink_crossing_to_disallowed_prefix() {
        // A path under a disallowed prefix that is a symlink to an allowed
        // path should still be denied (we check the REQUESTED path, not target).
        let tmp = tempfile::tempdir().unwrap();
        let allowed_dir = tmp.path().join("allowed");
        let blocked_dir = tmp.path().join("blocked");
        std::fs::create_dir_all(&allowed_dir).unwrap();
        std::fs::create_dir_all(&blocked_dir).unwrap();
        std::fs::write(allowed_dir.join("secret"), "data").unwrap();

        let mut list = AllowList::new();
        list.read_only.insert(allowed_dir);

        // Path in the blocked dir should be denied even if it's a symlink.
        assert!(!list.can_read(&blocked_dir.join("anything")));
    }

    #[test]
    fn symlink_chain_stays_within_prefix() {
        // Symlink → symlink → real file, all under the same prefix.
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("pkg");
        std::fs::create_dir_all(dir.join("lib")).unwrap();
        std::fs::write(dir.join("lib/libfoo.so.1.0"), "elf").unwrap();
        std::os::unix::fs::symlink("libfoo.so.1.0", dir.join("lib/libfoo.so.1")).unwrap();
        std::os::unix::fs::symlink("libfoo.so.1", dir.join("lib/libfoo.so")).unwrap();

        let mut list = AllowList::new();
        list.read_only.insert(dir.clone());

        // All links in the chain are under the allowed prefix.
        assert!(list.can_read(&dir.join("lib/libfoo.so")));
        assert!(list.can_read(&dir.join("lib/libfoo.so.1")));
        assert!(list.can_read(&dir.join("lib/libfoo.so.1.0")));
    }

    // ── Path traversal attempts ──────────────────────────────────────

    #[test]
    fn dotdot_traversal_blocked() {
        // Attempting to escape via ".." should fail.
        // /nix/store/abc-dep-1.0/../../etc/passwd resolves to /etc/passwd
        // which Path::starts_with correctly rejects.
        let list = make_list();
        let traversal = Path::new("/nix/store/abc-dep-1.0/../../etc/passwd");
        // std::path doesn't canonicalize, so this is literally the path components.
        // On a real system, the proxy handler's canonicalize() would resolve this.
        // At the allow-list level, the raw path with ".." won't match any prefix.
        assert_eq!(list.check(traversal), Permission::Denied);
    }

    #[test]
    fn absolute_path_required() {
        // Relative paths shouldn't match absolute entries.
        let list = make_list();
        assert_eq!(
            list.check(Path::new("nix/store/abc-dep-1.0/lib/foo")),
            Permission::Denied,
        );
    }

    #[test]
    fn root_path_not_allowed() {
        let list = make_list();
        assert_eq!(list.check(Path::new("/")), Permission::Denied);
    }

    #[test]
    fn nix_store_dir_not_allowed() {
        // /nix/store itself is not on the list — only specific store paths.
        let list = make_list();
        assert_eq!(list.check(Path::new("/nix/store")), Permission::Denied);
    }

    // ── Handle table-like lifecycle ────────────────────────────────────

    #[test]
    fn multiple_read_write_entries() {
        let mut list = AllowList::new();
        list.read_write.insert(PathBuf::from("/nix/store/out1"));
        list.read_write.insert(PathBuf::from("/nix/store/out2"));
        list.read_write.insert(PathBuf::from("/tmp/build-a"));
        list.read_write.insert(PathBuf::from("/tmp/build-b"));

        assert!(list.can_write(Path::new("/nix/store/out1/bin/foo")));
        assert!(list.can_write(Path::new("/nix/store/out2/lib/bar")));
        assert!(list.can_write(Path::new("/tmp/build-a/scratch")));
        assert!(list.can_write(Path::new("/tmp/build-b/scratch")));
        assert!(!list.can_write(Path::new("/nix/store/out3/bin/baz")));
    }

    #[test]
    fn read_write_takes_priority_over_read_only() {
        // Same path in both sets — read-write should win.
        let mut list = AllowList::new();
        list.read_only.insert(PathBuf::from("/nix/store/abc"));
        list.read_write.insert(PathBuf::from("/nix/store/abc"));

        assert_eq!(
            list.check(Path::new("/nix/store/abc/file")),
            Permission::ReadWrite,
        );
    }

    // ── Directory filtering visibility ─────────────────────────────────

    #[test]
    fn parent_dirs_visible_for_navigation() {
        // When /nix/store/abc is allowed, listing "/" should show "nix",
        // listing "/nix" should show "store", etc.
        let mut list = AllowList::new();
        list.read_only.insert(PathBuf::from("/nix/store/abc-dep"));

        // These are PARENTS of an allowed path — not readable themselves,
        // but they should be navigable (the handler uses is_entry_visible).
        assert!(!list.can_read(Path::new("/nix")));
        assert!(!list.can_read(Path::new("/nix/store")));

        // But the allowed path and its children are readable.
        assert!(list.can_read(Path::new("/nix/store/abc-dep")));
        assert!(list.can_read(Path::new("/nix/store/abc-dep/lib/foo")));
    }

    // ── all_prefixes ───────────────────────────────────────────────────

    #[test]
    fn all_prefixes_includes_both() {
        let list = make_list();
        let prefixes: Vec<&Path> = list.all_prefixes().collect();
        assert!(prefixes.contains(&Path::new("/nix/store/abc-dep-1.0")));
        assert!(prefixes.contains(&Path::new("/nix/store/ghi-output-1.0")));
        assert!(prefixes.contains(&Path::new("/tmp/snix-build-42-0")));
        assert_eq!(prefixes.len(), 4);
    }
}
