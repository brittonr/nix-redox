//! `stored` — Nix store scheme daemon for Redox OS.
//!
//! Serves `/nix/store/` paths via the Redox `store:` scheme, enabling
//! lazy NAR extraction on first access and transparent cache fallback.
//!
//! Architecture:
//!   1. Registers as the `store` scheme with the Redox kernel
//!   2. Processes open/read/close/stat/readdir via the scheme protocol
//!   3. On first access to an unextracted store path:
//!      a. Looks up the path in PathInfoDb
//!      b. Finds the NAR in the local cache
//!      c. Decompresses and extracts to /nix/store/
//!      d. Verifies the NAR hash
//!      e. Serves the requested file
//!   4. Subsequent accesses go directly to the filesystem
//!
//! Layout:
//! ```text
//! store:abc...-ripgrep/bin/rg   → /nix/store/abc...-ripgrep/bin/rg
//! store:                         → list all registered store paths
//! ```
//!
//! The daemon is optional. When not running, snix falls back to direct
//! filesystem operations at `/nix/store/`.

pub mod handles;
pub mod lazy;
pub mod resolve;

#[cfg(target_os = "redox")]
pub mod scheme;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

use crate::pathinfo::PathInfoDb;

/// A directory entry derived from a manifest (no filesystem I/O needed).
#[derive(Debug, Clone)]
pub struct ManifestDirEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub executable: bool,
}

/// Configuration for the store daemon.
#[derive(Debug, Clone)]
pub struct StoredConfig {
    /// Path to the local binary cache for lazy extraction.
    /// Default: `/nix/cache`
    pub cache_path: String,
    /// Path to the store directory.
    /// Default: `/nix/store`
    pub store_dir: String,
}

impl Default for StoredConfig {
    fn default() -> Self {
        Self {
            cache_path: "/nix/cache".to_string(),
            store_dir: "/nix/store".to_string(),
        }
    }
}

/// Core state for the store daemon.
///
/// Holds the PathInfoDb handle, the handle table, and tracks
/// in-progress extractions to prevent duplicate work.
pub struct StoreDaemon {
    /// PathInfo database for store path metadata.
    pub db: PathInfoDb,
    /// Open file/directory handles.
    pub handles: handles::HandleTable,
    /// Store paths currently being extracted (prevents concurrent extraction).
    pub extracting: Mutex<std::collections::HashSet<String>>,
    /// Daemon configuration.
    pub config: StoredConfig,
    /// Pre-opened root fd used for direct redoxfs access after `setrens`.
    pub root_fd: Option<usize>,
    /// Registered store path names known at daemon startup or via `.control`.
    /// Kept in memory so the scheme event loop never needs to scan PathInfoDb.
    pub registered_paths: BTreeSet<String>,
    /// Expected NAR hash per store path (hex or `sha256:hex`).
    /// Needed for lazy extraction without re-reading PathInfoDb in the event loop.
    pub nar_hashes: BTreeMap<String, String>,
    /// Cached file manifests (store_path_name → manifest entries).
    /// Loaded from PathInfoDb on first access. Enables getdents
    /// without filesystem I/O (which hangs on Redox scheme daemons).
    pub manifests: BTreeMap<String, Vec<crate::nar::ManifestEntry>>,
}

impl StoreDaemon {
    /// Create a new store daemon with the given config.
    pub fn new(config: StoredConfig) -> Result<Self, Box<dyn std::error::Error>> {
        let db = PathInfoDb::open()?;

        // Pre-load registered path names and file manifests from PathInfo.
        // This keeps PathInfoDb reads out of the scheme event loop.
        let mut registered_paths = BTreeSet::new();
        let mut nar_hashes = BTreeMap::new();
        let mut manifests = BTreeMap::new();
        if let Ok(paths) = db.list_paths() {
            for path in &paths {
                let name = path
                    .strip_prefix(&format!("{}/", config.store_dir))
                    .unwrap_or(path)
                    .to_string();
                registered_paths.insert(name.clone());

                if let Ok(Some(info)) = db.get(path) {
                    nar_hashes.insert(name.clone(), info.nar_hash.clone());
                    if !info.files.is_empty() {
                        manifests.insert(name, info.files);
                    }
                }
            }
        }
        let manifest_count = manifests.len();
        eprintln!("stored: loaded {manifest_count} manifests");

        // Use a worker-backed handle table. The I/O worker runs file
        // reads on a separate thread, avoiding the scheme event loop
        // hang that occurs when doing file: I/O from within a scheme
        // handler on Redox.
        //
        // root_fd is set later by scheme::run_daemon() before setrens.
        // Pass None here — the daemon will update it before the event loop.
        Ok(Self {
            db,
            handles: handles::HandleTable::with_io_worker(None),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config,
            root_fd: None,
            registered_paths,
            nar_hashes,
            manifests,
        })
    }

    /// Create a store daemon for testing with a custom PathInfoDb location.
    #[cfg(test)]
    pub fn new_at(
        pathinfo_dir: std::path::PathBuf,
        config: StoredConfig,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let db = PathInfoDb::open_at(pathinfo_dir)?;
        let mut registered_paths = BTreeSet::new();
        let mut nar_hashes = BTreeMap::new();
        let mut manifests = BTreeMap::new();
        if let Ok(paths) = db.list_paths() {
            for path in &paths {
                let name = path
                    .strip_prefix(&format!("{}/", config.store_dir))
                    .unwrap_or(path)
                    .to_string();
                registered_paths.insert(name.clone());
                if let Ok(Some(info)) = db.get(path) {
                    nar_hashes.insert(name.clone(), info.nar_hash.clone());
                    if !info.files.is_empty() {
                        manifests.insert(name, info.files);
                    }
                }
            }
        }
        Ok(Self {
            db,
            handles: handles::HandleTable::new(),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config,
            root_fd: None,
            registered_paths,
            nar_hashes,
            manifests,
        })
    }

    /// Load or refresh the manifest for a store path name.
    /// Reads from the PathInfo `files` field (no separate manifest file).
    ///
    /// ⚠️ Does filesystem I/O via `db.get()` — NOT safe from within
    /// Redox scheme event loops. Use `load_manifest_via_worker()` instead.
    pub fn load_manifest(&mut self, store_path_name: &str) {
        self.remember_store_path(store_path_name);
        let full_path = format!("{}/{}", self.config.store_dir, store_path_name);
        if let Ok(Some(info)) = self.db.get(&full_path) {
            if !info.files.is_empty() {
                self.manifests
                    .insert(store_path_name.to_string(), info.files);
            }
        }
    }

    /// Load a manifest for a store path via the I/O worker thread.
    ///
    /// Safe to call from within Redox scheme event loops because the
    /// actual file read happens on the worker's background thread,
    /// not the scheme handler thread.
    ///
    /// Returns `true` if the manifest was loaded (or was already cached).
    pub fn load_manifest_via_worker(&mut self, store_path_name: &str) -> bool {
        self.remember_store_path(store_path_name);

        // Already loaded?
        if self.manifests.contains_key(store_path_name) {
            return true;
        }

        eprintln!("stored: dynamic manifest load for {store_path_name}");

        // Compute the PathInfoDb JSON file path for this store path.
        let full_path = format!("{}/{}", self.config.store_dir, store_path_name);
        let hash = match crate::pathinfo::store_path_hash(&full_path) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("stored: can't compute hash for {store_path_name}: {e}");
                return false;
            }
        };

        let pathinfo_file = self.db.dir().join(format!("{hash}.json"));
        eprintln!("stored: reading {}", pathinfo_file.display());

        // Read the file via the I/O worker (background thread) or
        // direct I/O (tests without a worker).
        let data: Vec<u8> = if let Some(worker) = &self.handles.io_worker {
            eprintln!("stored: sending to I/O worker...");
            match worker.preload_file(&pathinfo_file) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!(
                        "stored: worker failed to read {}: {e}",
                        pathinfo_file.display()
                    );
                    return false;
                }
            }
        } else {
            match std::fs::read(&pathinfo_file) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!(
                        "stored: direct read failed for {}: {e}",
                        pathinfo_file.display()
                    );
                    return false;
                }
            }
        };

        // Parse JSON on the scheme handler thread (CPU-only, no I/O).
        let info: crate::pathinfo::PathInfo = match serde_json::from_slice(&data) {
            Ok(i) => i,
            Err(e) => {
                eprintln!("stored: failed to parse pathinfo for {store_path_name}: {e}");
                return false;
            }
        };

        if !info.files.is_empty() {
            eprintln!(
                "stored: dynamically loaded manifest for {store_path_name} ({} entries)",
                info.files.len()
            );
            self.manifests
                .insert(store_path_name.to_string(), info.files);
            true
        } else {
            eprintln!("stored: pathinfo for {store_path_name} has no file manifest");
            false
        }
    }

    /// Check if a store path is registered.
    pub fn is_registered_path(&self, store_path_name: &str) -> bool {
        self.registered_paths.contains(store_path_name)
    }

    /// Return the expected NAR hash for a store path.
    pub fn expected_nar_hash(&self, store_path_name: &str) -> Option<&str> {
        self.nar_hashes.get(store_path_name).map(String::as_str)
    }

    /// Remember a store path as registered.
    pub fn remember_store_path(&mut self, store_path_name: &str) {
        self.registered_paths.insert(store_path_name.to_string());
    }

    /// Remember or update the expected NAR hash for a store path.
    pub fn remember_nar_hash(&mut self, store_path_name: &str, nar_hash: &str) {
        self.remember_store_path(store_path_name);
        self.nar_hashes
            .insert(store_path_name.to_string(), nar_hash.to_string());
    }

    /// Return registered store path names in sorted order.
    pub fn list_registered_path_names(&self) -> Vec<String> {
        self.registered_paths.iter().cloned().collect()
    }

    /// Check whether a path exists according to the manifest.
    ///
    /// Returns:
    /// - `Some(true)` if the manifest contains the exact path or an implied dir
    /// - `Some(false)` if the manifest is loaded and the path is absent
    /// - `None` if no manifest is loaded for this store path
    pub fn manifest_contains_path(&self, store_path_name: &str, subpath: &str) -> Option<bool> {
        let manifest = self.manifests.get(store_path_name)?;
        let subpath = subpath.trim_matches('/');

        if subpath.is_empty() {
            return Some(true);
        }

        for entry in manifest {
            if entry.path == subpath {
                return Some(true);
            }
        }

        let prefix = format!("{subpath}/");
        for entry in manifest {
            if entry.path.starts_with(&prefix) {
                return Some(true);
            }
        }

        Some(false)
    }

    /// Check if a subpath is a directory according to the manifest.
    ///
    /// Returns `true` if the manifest contains a "dir" entry for this
    /// exact path, or if any manifest entry has this path as a prefix
    /// (meaning files exist inside it). Returns `true` as fallback if
    /// no manifest is available (safer to treat as dir than to attempt
    /// a filesystem open that could hang the event loop).
    pub fn is_directory_in_manifest(&self, store_path_name: &str, subpath: &str) -> bool {
        let manifest = match self.manifests.get(store_path_name) {
            Some(m) => m,
            // No manifest → assume directory (safe default: open_dir_unchecked
            // doesn't do I/O, whereas open_file does).
            None => return true,
        };

        let subpath = subpath.trim_matches('/');

        // Check for an exact "dir" entry.
        for entry in manifest {
            if entry.path == subpath && entry.entry_type == "dir" {
                return true;
            }
        }

        // Check if any entry has this as a prefix (e.g., "bin/rg" starts
        // with "bin/", so "bin" is implicitly a directory).
        let prefix = format!("{subpath}/");
        for entry in manifest {
            if entry.path.starts_with(&prefix) {
                return true;
            }
        }

        false
    }

    /// Look up file metadata (size, executable) from the manifest.
    ///
    /// Returns `(size, executable)`. Falls back to `(0, false)` if the
    /// entry isn't in the manifest (the lazy file handle will get real
    /// metadata on first read).
    pub fn file_metadata_from_manifest(&self, store_path_name: &str, subpath: &str) -> (u64, bool) {
        let manifest = match self.manifests.get(store_path_name) {
            Some(m) => m,
            None => return (0, false),
        };
        let subpath = subpath.trim_matches('/');
        for entry in manifest {
            if entry.path == subpath {
                return (entry.size, entry.executable);
            }
        }
        (0, false)
    }

    /// List directory entries from the manifest for a given subpath.
    ///
    /// Returns `None` if no manifest is available for this store path.
    pub fn list_from_manifest(
        &self,
        store_path_name: &str,
        subpath: &str,
    ) -> Option<Vec<ManifestDirEntry>> {
        let manifest = self.manifests.get(store_path_name)?;

        let prefix = if subpath.is_empty() {
            String::new()
        } else {
            format!("{}/", subpath.trim_end_matches('/'))
        };

        let mut entries = BTreeMap::new();
        for entry in manifest {
            let rel = if prefix.is_empty() {
                &entry.path
            } else if let Some(stripped) = entry.path.strip_prefix(&prefix) {
                stripped
            } else {
                continue;
            };

            // Only direct children (no nested paths).
            if let Some(slash_pos) = rel.find('/') {
                // This is a nested entry — the directory itself is a child.
                let dir_name = &rel[..slash_pos];
                entries
                    .entry(dir_name.to_string())
                    .or_insert(ManifestDirEntry {
                        name: dir_name.to_string(),
                        is_dir: true,
                        is_symlink: false,
                        size: 0,
                        executable: false,
                    });
            } else if !rel.is_empty() {
                entries.insert(
                    rel.to_string(),
                    ManifestDirEntry {
                        name: rel.to_string(),
                        is_dir: entry.entry_type == "dir",
                        is_symlink: entry.entry_type == "symlink",
                        size: entry.size,
                        executable: entry.executable,
                    },
                );
            }
        }

        let mut result: Vec<ManifestDirEntry> = entries.into_values().collect();
        result.sort_by(|a, b| a.name.cmp(&b.name));
        Some(result)
    }
}

/// Entry point for `snix stored` — runs the scheme daemon.
///
/// On Redox: registers the `store` scheme and enters the request loop.
/// On other platforms: prints an error (scheme daemons are Redox-only).
pub fn run(config: StoredConfig) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "redox")]
    {
        scheme::run_daemon(config)
    }

    #[cfg(not(target_os = "redox"))]
    {
        let _ = config;
        Err("stored: scheme daemons are only supported on Redox OS".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nar::ManifestEntry;

    fn make_entry(path: &str, entry_type: &str) -> ManifestEntry {
        ManifestEntry {
            path: path.to_string(),
            entry_type: entry_type.to_string(),
            size: 0,
            executable: false,
        }
    }

    /// Helper: create a StoreDaemon with pre-loaded manifests (no PathInfoDb).
    fn daemon_with_manifest(store_path_name: &str, entries: Vec<ManifestEntry>) -> StoreDaemon {
        let mut manifests = BTreeMap::new();
        manifests.insert(store_path_name.to_string(), entries);
        StoreDaemon {
            db: PathInfoDb::open_at(std::path::PathBuf::from("/tmp/snix-test-nonexistent"))
                .unwrap_or_else(|_| {
                    std::fs::create_dir_all("/tmp/snix-test-stored-db").ok();
                    PathInfoDb::open_at(std::path::PathBuf::from("/tmp/snix-test-stored-db"))
                        .unwrap()
                }),
            handles: handles::HandleTable::new(),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config: StoredConfig::default(),
            root_fd: None,
            registered_paths: BTreeSet::from([store_path_name.to_string()]),
            nar_hashes: BTreeMap::new(),
            manifests,
        }
    }

    #[test]
    fn is_directory_explicit_dir_entry() {
        let d = daemon_with_manifest(
            "abc-pkg",
            vec![make_entry("bin", "dir"), make_entry("bin/rg", "file")],
        );
        assert!(d.is_directory_in_manifest("abc-pkg", "bin"));
    }

    #[test]
    fn is_directory_implicit_from_children() {
        // No explicit "bin" dir entry, but "bin/rg" implies "bin" is a directory.
        let d = daemon_with_manifest("abc-pkg", vec![make_entry("bin/rg", "file")]);
        assert!(d.is_directory_in_manifest("abc-pkg", "bin"));
    }

    #[test]
    fn is_not_directory_for_file() {
        let d = daemon_with_manifest(
            "abc-pkg",
            vec![make_entry("bin", "dir"), make_entry("bin/rg", "file")],
        );
        assert!(!d.is_directory_in_manifest("abc-pkg", "bin/rg"));
    }

    #[test]
    fn is_directory_unknown_manifest_defaults_true() {
        let d = daemon_with_manifest("abc-pkg", vec![]);
        // Unknown store path → default to true (safe: dir open doesn't do I/O).
        assert!(d.is_directory_in_manifest("other-pkg", "bin"));
    }

    #[test]
    fn is_directory_nested_subpath() {
        let d = daemon_with_manifest("abc-pkg", vec![make_entry("share/man/man1/rg.1", "file")]);
        assert!(d.is_directory_in_manifest("abc-pkg", "share"));
        assert!(d.is_directory_in_manifest("abc-pkg", "share/man"));
        assert!(d.is_directory_in_manifest("abc-pkg", "share/man/man1"));
        assert!(!d.is_directory_in_manifest("abc-pkg", "share/man/man1/rg.1"));
    }

    #[test]
    fn is_directory_trims_slashes() {
        let d = daemon_with_manifest("abc-pkg", vec![make_entry("bin/rg", "file")]);
        assert!(d.is_directory_in_manifest("abc-pkg", "bin/"));
        assert!(d.is_directory_in_manifest("abc-pkg", "/bin/"));
        assert!(d.is_directory_in_manifest("abc-pkg", "/bin"));
    }

    #[test]
    fn list_from_manifest_root() {
        let d = daemon_with_manifest(
            "abc-pkg",
            vec![
                make_entry("bin", "dir"),
                make_entry("bin/rg", "file"),
                make_entry("share", "dir"),
                make_entry("share/man/man1/rg.1", "file"),
            ],
        );
        let entries = d.list_from_manifest("abc-pkg", "").unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["bin", "share"]);
    }

    #[test]
    fn list_from_manifest_subdir() {
        let d = daemon_with_manifest(
            "abc-pkg",
            vec![
                make_entry("bin", "dir"),
                make_entry("bin/rg", "file"),
                make_entry("bin/rg-readme", "file"),
            ],
        );
        let entries = d.list_from_manifest("abc-pkg", "bin").unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["rg", "rg-readme"]);
    }

    #[test]
    fn load_manifest_via_worker_already_cached() {
        let mut d = daemon_with_manifest("abc-pkg", vec![make_entry("bin/rg", "file")]);
        // Already cached → returns true without I/O.
        assert!(d.load_manifest_via_worker("abc-pkg"));
        assert!(d.manifests.contains_key("abc-pkg"));
    }

    #[test]
    fn load_manifest_via_worker_not_in_pathinfodb() {
        // Create a daemon with empty manifests and a real (but empty) PathInfoDb.
        let dir = std::path::PathBuf::from("/tmp/snix-test-load-manifest-worker");
        std::fs::create_dir_all(&dir).ok();
        let mut d = StoreDaemon {
            db: PathInfoDb::open_at(dir).unwrap(),
            handles: handles::HandleTable::new(),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config: StoredConfig::default(),
            root_fd: None,
            registered_paths: BTreeSet::new(),
            nar_hashes: BTreeMap::new(),
            manifests: BTreeMap::new(),
        };
        // Store path not registered → returns false.
        assert!(!d.load_manifest_via_worker("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nonexistent"));
    }

    #[test]
    fn load_manifest_via_worker_from_pathinfodb() {
        // Create a PathInfoDb entry, then load the manifest dynamically.
        let dir = std::path::PathBuf::from("/tmp/snix-test-load-manifest-dynamic");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).ok();

        let db = PathInfoDb::open_at(dir.clone()).unwrap();

        // Register a store path with file manifest data.
        let store_path = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-pkg";
        let info = crate::pathinfo::PathInfo {
            store_path: store_path.to_string(),
            nar_hash: "0000000000000000000000000000000000000000000000000000000000000000"
                .to_string(),
            nar_size: 100,
            references: vec![],
            deriver: None,
            registration_time: "2026-01-01T00:00:00Z".to_string(),
            signatures: vec![],
            files: vec![make_entry("bin", "dir"), make_entry("bin/hello", "file")],
        };
        // register() writes the full PathInfo JSON including the files field.
        db.register(&info).unwrap();

        // Create a daemon with no pre-loaded manifests, pointing at this PathInfoDb.
        let mut d = StoreDaemon {
            db: PathInfoDb::open_at(dir).unwrap(),
            handles: handles::HandleTable::new(), // No worker → falls back to direct read
            extracting: Mutex::new(std::collections::HashSet::new()),
            config: StoredConfig::default(),
            root_fd: None,
            registered_paths: BTreeSet::new(),
            nar_hashes: BTreeMap::new(),
            manifests: BTreeMap::new(),
        };

        // Manifest not loaded yet.
        assert!(!d
            .manifests
            .contains_key("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-pkg"));

        // Dynamic load via worker (falls back to direct read since no worker).
        assert!(d.load_manifest_via_worker("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-pkg"));

        // Now the manifest should be cached.
        assert!(d
            .manifests
            .contains_key("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-pkg"));
        assert!(d.is_registered_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-pkg"));
        let manifest = d
            .manifests
            .get("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-pkg")
            .unwrap();
        assert_eq!(manifest.len(), 2);
        assert_eq!(manifest[0].path, "bin");
        assert_eq!(manifest[1].path, "bin/hello");
    }

    #[test]
    fn manifest_contains_path_reports_present_and_missing() {
        let d = daemon_with_manifest(
            "abc-pkg",
            vec![make_entry("bin", "dir"), make_entry("bin/rg", "file")],
        );

        assert_eq!(d.manifest_contains_path("abc-pkg", "bin"), Some(true));
        assert_eq!(d.manifest_contains_path("abc-pkg", "bin/rg"), Some(true));
        assert_eq!(d.manifest_contains_path("abc-pkg", "share"), Some(false));
        assert_eq!(d.manifest_contains_path("missing", "bin"), None);
    }

    #[test]
    fn registered_path_names_are_sorted() {
        let mut d = daemon_with_manifest("zzz-pkg", vec![]);
        d.remember_store_path("aaa-pkg");
        d.remember_store_path("mmm-pkg");

        assert_eq!(
            d.list_registered_path_names(),
            vec!["aaa-pkg", "mmm-pkg", "zzz-pkg"]
        );
    }
}
