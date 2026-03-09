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
pub mod resolve;
pub mod lazy;

#[cfg(target_os = "redox")]
pub mod scheme;

use std::collections::BTreeMap;
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
    /// Cached file manifests (store_path_name → manifest entries).
    /// Loaded from PathInfoDb on first access. Enables getdents
    /// without filesystem I/O (which hangs on Redox scheme daemons).
    pub manifests: BTreeMap<String, Vec<crate::nar::ManifestEntry>>,
}

impl StoreDaemon {
    /// Create a new store daemon with the given config.
    pub fn new(config: StoredConfig) -> Result<Self, Box<dyn std::error::Error>> {
        let db = PathInfoDb::open()?;

        // Pre-load file manifests from PathInfo entries.
        // These are embedded in the PathInfo JSON `files` field.
        let mut manifests = BTreeMap::new();
        if let Ok(paths) = db.list_paths() {
            for path in &paths {
                if let Ok(Some(info)) = db.get(path) {
                    if !info.files.is_empty() {
                        let name = path
                            .strip_prefix(&format!("{}/", config.store_dir))
                            .unwrap_or(path)
                            .to_string();
                        manifests.insert(name, info.files);
                    }
                }
            }
        }
        let manifest_count = manifests.len();
        eprintln!("stored: loaded {manifest_count} manifests");

        Ok(Self {
            db,
            handles: handles::HandleTable::new(),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config,
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
        Ok(Self {
            db,
            handles: handles::HandleTable::new(),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config,
            manifests: BTreeMap::new(),
        })
    }

    /// Load or refresh the manifest for a store path name.
    /// Reads from the PathInfo `files` field (no separate manifest file).
    pub fn load_manifest(&mut self, store_path_name: &str) {
        let full_path = format!("{}/{}", self.config.store_dir, store_path_name);
        if let Ok(Some(info)) = self.db.get(&full_path) {
            if !info.files.is_empty() {
                self.manifests.insert(store_path_name.to_string(), info.files);
            }
        }
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
                entries.entry(dir_name.to_string()).or_insert(ManifestDirEntry {
                    name: dir_name.to_string(),
                    is_dir: true,
                    is_symlink: false,
                    size: 0,
                    executable: false,
                });
            } else if !rel.is_empty() {
                entries.insert(rel.to_string(), ManifestDirEntry {
                    name: rel.to_string(),
                    is_dir: entry.entry_type == "dir",
                    is_symlink: entry.entry_type == "symlink",
                    size: entry.size,
                    executable: entry.executable,
                });
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
