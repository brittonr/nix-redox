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
}

impl StoreDaemon {
    /// Create a new store daemon with the given config.
    pub fn new(config: StoredConfig) -> Result<Self, Box<dyn std::error::Error>> {
        let db = PathInfoDb::open()?;
        Ok(Self {
            db,
            handles: handles::HandleTable::new(),
            extracting: Mutex::new(std::collections::HashSet::new()),
            config,
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
        })
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
