//! JSON-based path metadata database for the local Nix store.
//!
//! Each registered store path gets a JSON file at:
//!   `/nix/var/snix/pathinfo/{nixbase32-hash}.json`
//!
//! No SQLite, no daemon — just filesystem operations.
//! Designed for <10k paths where simplicity beats performance.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;
use serde::{Deserialize, Serialize};

/// Default base directory for snix metadata
pub const SNIX_VAR_DIR: &str = "/nix/var/snix";

/// Per-path metadata stored as JSON
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PathInfo {
    /// Full absolute store path (e.g., /nix/store/abc...-hello-2.12.1)
    pub store_path: String,

    /// NAR hash (SHA-256, hex-encoded)
    pub nar_hash: String,

    /// NAR size in bytes (uncompressed)
    pub nar_size: u64,

    /// Store paths this path directly references
    pub references: Vec<String>,

    /// The .drv that produced this path (if known)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deriver: Option<String>,

    /// ISO 8601 timestamp when this path was registered locally
    pub registration_time: String,

    /// Binary cache signatures (for future verification)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signatures: Vec<String>,
}

/// Filesystem-backed path info database.
///
/// Each store path's metadata is stored in its own JSON file,
/// keyed by the nixbase32 hash from the store path.
pub struct PathInfoDb {
    pathinfo_dir: PathBuf,
}

impl PathInfoDb {
    /// Open the database, creating the directory if needed.
    pub fn open() -> io::Result<Self> {
        Self::open_at(Path::new(SNIX_VAR_DIR).join("pathinfo"))
    }

    /// Open the database at a custom path (for testing).
    pub fn open_at(pathinfo_dir: PathBuf) -> io::Result<Self> {
        fs::create_dir_all(&pathinfo_dir)?;
        Ok(Self { pathinfo_dir })
    }

    /// Look up metadata for a store path. Returns `None` if not registered.
    pub fn get(&self, store_path: &str) -> Result<Option<PathInfo>, PathInfoError> {
        let file = self.info_file(store_path)?;
        if !file.exists() {
            return Ok(None);
        }
        let content = fs::read_to_string(&file)
            .map_err(|e| PathInfoError::Io(format!("reading {}: {e}", file.display())))?;
        let info: PathInfo = serde_json::from_str(&content)
            .map_err(|e| PathInfoError::Corrupt(format!("{}: {e}", file.display())))?;
        Ok(Some(info))
    }

    /// Register a store path (write its JSON file).
    /// Overwrites if already registered.
    pub fn register(&self, info: &PathInfo) -> Result<(), PathInfoError> {
        let file = self.info_file(&info.store_path)?;
        let json = serde_json::to_string_pretty(info)
            .map_err(|e| PathInfoError::Io(format!("serializing: {e}")))?;
        fs::write(&file, json)
            .map_err(|e| PathInfoError::Io(format!("writing {}: {e}", file.display())))?;
        Ok(())
    }

    /// Check whether a store path is registered.
    pub fn is_registered(&self, store_path: &str) -> bool {
        self.info_file(store_path)
            .map(|f| f.exists())
            .unwrap_or(false)
    }

    /// Delete the metadata for a store path.
    pub fn delete(&self, store_path: &str) -> Result<(), PathInfoError> {
        let file = self.info_file(store_path)?;
        if file.exists() {
            fs::remove_file(&file)
                .map_err(|e| PathInfoError::Io(format!("deleting {}: {e}", file.display())))?;
        }
        Ok(())
    }

    /// List all registered store paths (scans the directory).
    pub fn list_paths(&self) -> Result<Vec<String>, PathInfoError> {
        let mut paths = Vec::new();
        for entry in fs::read_dir(&self.pathinfo_dir)
            .map_err(|e| PathInfoError::Io(format!("reading dir: {e}")))?
        {
            let entry =
                entry.map_err(|e| PathInfoError::Io(format!("reading entry: {e}")))?;
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if !name_str.ends_with(".json") {
                continue;
            }
            let content = fs::read_to_string(entry.path())
                .map_err(|e| PathInfoError::Io(format!("reading {}: {e}", name_str)))?;
            if let Ok(info) = serde_json::from_str::<PathInfo>(&content) {
                paths.push(info.store_path);
            }
        }
        paths.sort();
        Ok(paths)
    }

    /// Return the set of all registered store paths (for GC).
    pub fn all_paths_set(&self) -> Result<BTreeSet<String>, PathInfoError> {
        Ok(self.list_paths()?.into_iter().collect())
    }

    /// Compute the JSON file path for a given store path.
    fn info_file(&self, store_path: &str) -> Result<PathBuf, PathInfoError> {
        let hash = store_path_hash(store_path)?;
        Ok(self.pathinfo_dir.join(format!("{hash}.json")))
    }
}

/// Extract the nixbase32 hash component from a full store path.
///
/// `/nix/store/abc123...-hello-1.0` → `"abc123..."`
pub fn store_path_hash(store_path: &str) -> Result<String, PathInfoError> {
    let sp = StorePath::<String>::from_absolute_path(store_path.as_bytes())
        .map_err(|e| PathInfoError::InvalidPath(format!("{store_path}: {e}")))?;
    Ok(nixbase32::encode(sp.digest()))
}

/// Get the current time as an ISO 8601 string (same logic as system.rs).
pub fn current_timestamp() -> String {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => {
            let secs = d.as_secs();
            let days = secs / 86400;
            let remaining = secs % 86400;
            let hours = remaining / 3600;
            let minutes = (remaining % 3600) / 60;
            let seconds = remaining % 60;
            let (year, month, day) = days_to_date(days);
            format!("{year:04}-{month:02}-{day:02}T{hours:02}:{minutes:02}:{seconds:02}Z")
        }
        Err(_) => String::new(),
    }
}

/// Howard Hinnant's civil days algorithm.
fn days_to_date(days: u64) -> (u64, u64, u64) {
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ===== Errors =====

#[derive(Debug)]
pub enum PathInfoError {
    /// Invalid store path format
    InvalidPath(String),
    /// Filesystem I/O failure
    Io(String),
    /// Corrupt JSON file
    Corrupt(String),
}

impl std::fmt::Display for PathInfoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidPath(s) => write!(f, "invalid store path: {s}"),
            Self::Io(s) => write!(f, "I/O error: {s}"),
            Self::Corrupt(s) => write!(f, "corrupt pathinfo: {s}"),
        }
    }
}

impl std::error::Error for PathInfoError {}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // Valid nixbase32 test store paths (alphabet: 0123456789abcdfghijklmnpqrsvwxyz)
    const P_HELLO: &str = "/nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-hello-1.0";
    const P_GLIBC: &str = "/nix/store/6h4pzdrnfnl1npqz7j1hs2n1h9s6rp9s-glibc-2.35";
    const P_A: &str = "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-a-1.0";
    const P_B: &str = "/nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-b-2.0";
    const P_C: &str = "/nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-c-3.0";

    fn sample_info() -> PathInfo {
        PathInfo {
            store_path: P_HELLO.to_string(),
            nar_hash: "abc123def456".to_string(),
            nar_size: 12345,
            references: vec![
                P_HELLO.to_string(),
                P_GLIBC.to_string(),
            ],
            deriver: Some("/nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-hello-1.0.drv".to_string()),
            registration_time: "2026-02-20T12:00:00Z".to_string(),
            signatures: vec!["cache.nixos.org-1:abc...".to_string()],
        }
    }

    #[test]
    fn pathinfo_serialize_roundtrip() {
        let info = sample_info();
        let json = serde_json::to_string_pretty(&info).unwrap();
        let parsed: PathInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(info, parsed);
    }

    #[test]
    fn pathinfo_camel_case_keys() {
        let info = sample_info();
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("\"storePath\""));
        assert!(json.contains("\"narHash\""));
        assert!(json.contains("\"narSize\""));
        assert!(json.contains("\"registrationTime\""));
    }

    #[test]
    fn pathinfo_skip_empty_signatures() {
        let mut info = sample_info();
        info.signatures = vec![];
        let json = serde_json::to_string(&info).unwrap();
        assert!(!json.contains("signatures"));
    }

    #[test]
    fn pathinfo_skip_none_deriver() {
        let mut info = sample_info();
        info.deriver = None;
        let json = serde_json::to_string(&info).unwrap();
        assert!(!json.contains("deriver"));
    }

    #[test]
    fn pathinfo_deserialize_without_optional_fields() {
        let json = r#"{
            "storePath": "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-hello-1.0",
            "narHash": "abc",
            "narSize": 100,
            "references": [],
            "registrationTime": "2026-01-01T00:00:00Z"
        }"#;
        let info: PathInfo = serde_json::from_str(json).unwrap();
        assert!(info.deriver.is_none());
        assert!(info.signatures.is_empty());
    }

    #[test]
    fn store_path_hash_valid() {
        let hash = store_path_hash(P_HELLO).unwrap();
        assert_eq!(hash, "5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r");
    }

    #[test]
    fn store_path_hash_invalid() {
        assert!(store_path_hash("/tmp/not-a-store-path").is_err());
        assert!(store_path_hash("relative-path").is_err());
    }

    // ===== Database Tests =====

    #[test]
    fn db_open_creates_dir() {
        let tmp = TempDir::new().unwrap();
        let db_dir = tmp.path().join("pathinfo");
        assert!(!db_dir.exists());

        let _db = PathInfoDb::open_at(db_dir.clone()).unwrap();
        assert!(db_dir.exists());
    }

    #[test]
    fn db_register_and_get() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let info = sample_info();
        db.register(&info).unwrap();

        let loaded = db.get(&info.store_path).unwrap();
        assert!(loaded.is_some());
        assert_eq!(loaded.unwrap(), info);
    }

    #[test]
    fn db_get_unregistered_returns_none() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let result = db.get("/nix/store/cn8r5krrhrr7rrqz3q7nr8r7n5s2sp5s-missing-1.0").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn db_is_registered() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let info = sample_info();
        assert!(!db.is_registered(&info.store_path));

        db.register(&info).unwrap();
        assert!(db.is_registered(&info.store_path));
    }

    #[test]
    fn db_delete() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let info = sample_info();
        db.register(&info).unwrap();
        assert!(db.is_registered(&info.store_path));

        db.delete(&info.store_path).unwrap();
        assert!(!db.is_registered(&info.store_path));
    }

    #[test]
    fn db_delete_nonexistent_is_ok() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        // Deleting something not registered should succeed
        db.delete("/nix/store/cn8r5krrhrr7rrqz3q7nr8r7n5s2sp5s-nope-1.0").unwrap();
    }

    #[test]
    fn db_list_paths_empty() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let paths = db.list_paths().unwrap();
        assert!(paths.is_empty());
    }

    #[test]
    fn db_list_paths_sorted() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        // Each path has a different hash → different JSON file
        let paths = [P_C, P_A, P_B]; // register out of order
        for path in paths {
            let info = PathInfo {
                store_path: path.to_string(),
                nar_hash: "hash".to_string(),
                nar_size: 100,
                references: vec![],
                deriver: None,
                registration_time: "2026-01-01T00:00:00Z".to_string(),
                signatures: vec![],
            };
            db.register(&info).unwrap();
        }

        let listed = db.list_paths().unwrap();
        assert_eq!(listed.len(), 3);
        // Should be sorted alphabetically
        assert!(listed[0] < listed[1]);
        assert!(listed[1] < listed[2]);
    }

    #[test]
    fn db_list_multiple_paths() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let paths_to_register = [P_HELLO, P_GLIBC, P_A];

        for path in paths_to_register {
            let info = PathInfo {
                store_path: path.to_string(),
                nar_hash: "hash".to_string(),
                nar_size: 100,
                references: vec![],
                deriver: None,
                registration_time: "2026-01-01T00:00:00Z".to_string(),
                signatures: vec![],
            };
            db.register(&info).unwrap();
        }

        let listed = db.list_paths().unwrap();
        assert_eq!(listed.len(), 3);
        // Should be sorted
        assert!(listed[0] < listed[1]);
        assert!(listed[1] < listed[2]);
    }

    #[test]
    fn db_register_overwrites() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let mut info = sample_info();
        info.nar_size = 100;
        db.register(&info).unwrap();

        info.nar_size = 200;
        db.register(&info).unwrap();

        let loaded = db.get(&info.store_path).unwrap().unwrap();
        assert_eq!(loaded.nar_size, 200);
    }

    #[test]
    fn db_all_paths_set() {
        let tmp = TempDir::new().unwrap();
        let db = PathInfoDb::open_at(tmp.path().join("pathinfo")).unwrap();

        let paths = [P_A, P_B];

        for path in paths {
            db.register(&PathInfo {
                store_path: path.to_string(),
                nar_hash: "h".to_string(),
                nar_size: 0,
                references: vec![],
                deriver: None,
                registration_time: "t".to_string(),
                signatures: vec![],
            }).unwrap();
        }

        let set = db.all_paths_set().unwrap();
        assert_eq!(set.len(), 2);
        for path in paths {
            assert!(set.contains(path));
        }
    }

    #[test]
    fn db_corrupt_json_returns_error() {
        let tmp = TempDir::new().unwrap();
        let db_dir = tmp.path().join("pathinfo");
        fs::create_dir_all(&db_dir).unwrap();

        // Write garbage to a JSON file keyed by P_HELLO's hash
        fs::write(db_dir.join("5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r.json"), "not json").unwrap();

        let db = PathInfoDb::open_at(db_dir).unwrap();
        let result = db.get(P_HELLO);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("corrupt"));
    }

    #[test]
    fn current_timestamp_nonempty() {
        let ts = current_timestamp();
        assert!(!ts.is_empty());
        assert!(ts.contains('T'));
        assert!(ts.ends_with('Z'));
    }
}
