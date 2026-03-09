//! Store path resolution for the store scheme daemon.
//!
//! Parses scheme-relative paths (e.g., `abc...-ripgrep/bin/rg`) into:
//!   - Store path hash (32 nixbase32 chars)
//!   - Store path name (e.g., `abc...-ripgrep`)
//!   - Subpath within the store path (e.g., `bin/rg`)
//!
//! Validates that the store path is registered in PathInfoDb before
//! resolving to a filesystem path.

use std::path::{Path, PathBuf};

use crate::pathinfo::PathInfoDb;

/// A parsed store scheme path.
#[derive(Debug, Clone, PartialEq)]
pub enum ResolvedPath {
    /// The store root — list all store paths.
    Root,
    /// A store path directory (e.g., `abc...-ripgrep`).
    /// Contains the full store path name.
    StorePathRoot { store_path_name: String },
    /// A subpath within a store path (e.g., `abc...-ripgrep/bin/rg`).
    SubPath {
        store_path_name: String,
        subpath: String,
    },
}

/// Errors from store path resolution.
#[derive(Debug)]
pub enum ResolveError {
    /// The store path hash is malformed (not 32 nixbase32 chars).
    InvalidHash(String),
    /// The store path is not registered in PathInfoDb.
    NotRegistered(String),
    /// The resolved filesystem path does not exist (after extraction).
    NotFound(String),
    /// Path traversal attempt (contains `..`).
    PathTraversal(String),
}

impl std::fmt::Display for ResolveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidHash(h) => write!(f, "invalid store path hash: {h}"),
            Self::NotRegistered(p) => write!(f, "store path not registered: {p}"),
            Self::NotFound(p) => write!(f, "path not found: {p}"),
            Self::PathTraversal(p) => write!(f, "path traversal rejected: {p}"),
        }
    }
}

impl std::error::Error for ResolveError {}

/// Parse a scheme-relative path into a `ResolvedPath`.
///
/// The path comes from the scheme open call with the `store:` prefix stripped.
/// Examples:
///   - `""` or `"/"` → `Root`
///   - `"abc...-ripgrep"` → `StorePathRoot`
///   - `"abc...-ripgrep/bin/rg"` → `SubPath`
pub fn parse_scheme_path(path: &str) -> Result<ResolvedPath, ResolveError> {
    let path = path.trim_matches('/');

    if path.is_empty() {
        return Ok(ResolvedPath::Root);
    }

    // Reject path traversal.
    if path.contains("..") {
        return Err(ResolveError::PathTraversal(path.to_string()));
    }

    // Split into store path name and optional subpath.
    let (store_path_name, subpath) = match path.find('/') {
        Some(pos) => (&path[..pos], Some(&path[pos + 1..])),
        None => (path, None),
    };

    // Validate store path format: must start with 32 nixbase32 chars + '-'.
    validate_store_path_name(store_path_name)?;

    match subpath {
        None | Some("") => Ok(ResolvedPath::StorePathRoot {
            store_path_name: store_path_name.to_string(),
        }),
        Some(sub) => Ok(ResolvedPath::SubPath {
            store_path_name: store_path_name.to_string(),
            subpath: sub.to_string(),
        }),
    }
}

/// Validate that a store path name has the expected format: `{32-char-hash}-{name}`.
fn validate_store_path_name(name: &str) -> Result<(), ResolveError> {
    // Must be at least 34 chars: 32 hash + '-' + at least 1 name char.
    if name.len() < 34 {
        return Err(ResolveError::InvalidHash(name.to_string()));
    }

    let hash_part = &name[..32];
    if name.as_bytes()[32] != b'-' {
        return Err(ResolveError::InvalidHash(name.to_string()));
    }

    // Validate nixbase32 characters: 0-9, a-d, f-n, p-s, v-z
    // (no 'e', 'o', 't', 'u')
    for ch in hash_part.chars() {
        if !is_nixbase32(ch) {
            return Err(ResolveError::InvalidHash(name.to_string()));
        }
    }

    Ok(())
}

/// Check if a character is valid nixbase32.
fn is_nixbase32(c: char) -> bool {
    matches!(c, '0'..='9' | 'a'..='d' | 'f'..='n' | 'p'..='s' | 'v'..='z')
}

/// Resolve a scheme path to an absolute filesystem path.
///
/// Returns the absolute path under `store_dir` (typically `/nix/store/`).
/// Does NOT check if the path exists — that's the caller's job
/// (to decide whether to trigger lazy extraction).
pub fn to_filesystem_path(
    resolved: &ResolvedPath,
    store_dir: &str,
) -> Option<PathBuf> {
    match resolved {
        ResolvedPath::Root => Some(PathBuf::from(store_dir)),
        ResolvedPath::StorePathRoot { store_path_name } => {
            Some(PathBuf::from(store_dir).join(store_path_name))
        }
        ResolvedPath::SubPath {
            store_path_name,
            subpath,
        } => Some(
            PathBuf::from(store_dir)
                .join(store_path_name)
                .join(subpath),
        ),
    }
}

/// Check if a store path is registered in PathInfoDb.
pub fn is_registered(
    db: &PathInfoDb,
    store_path_name: &str,
    store_dir: &str,
) -> bool {
    let abs_path = format!("{store_dir}/{store_path_name}");
    db.is_registered(&abs_path)
}

/// Check if a store path is extracted (exists on the filesystem).
pub fn is_extracted(store_path_name: &str, store_dir: &str) -> bool {
    let abs_path = PathBuf::from(store_dir).join(store_path_name);
    abs_path.exists()
}

/// List all registered store path names from PathInfoDb.
pub fn list_store_paths(
    db: &PathInfoDb,
    store_dir: &str,
) -> Result<Vec<StorePathStatus>, Box<dyn std::error::Error>> {
    let paths = db.list_paths()?;
    let prefix = format!("{store_dir}/");

    let mut result = Vec::new();
    for path in paths {
        let name = path
            .strip_prefix(&prefix)
            .unwrap_or(&path)
            .to_string();
        let extracted = Path::new(&path).exists();
        result.push(StorePathStatus { name, extracted });
    }

    result.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(result)
}

/// Status of a store path.
#[derive(Debug, Clone)]
pub struct StorePathStatus {
    /// Store path name (e.g., `abc...-ripgrep`).
    pub name: String,
    /// Whether the path has been extracted to the filesystem.
    pub extracted: bool,
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // Valid nixbase32 test hashes (32 chars, alphabet: 0-9a-df-np-sv-z)
    const VALID_HASH: &str = "1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r";
    const VALID_NAME: &str = "1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ripgrep-14.1.0";

    #[test]
    fn parse_root() {
        assert_eq!(parse_scheme_path("").unwrap(), ResolvedPath::Root);
        assert_eq!(parse_scheme_path("/").unwrap(), ResolvedPath::Root);
        assert_eq!(parse_scheme_path("//").unwrap(), ResolvedPath::Root);
    }

    #[test]
    fn parse_store_path_root() {
        let r = parse_scheme_path(VALID_NAME).unwrap();
        assert_eq!(
            r,
            ResolvedPath::StorePathRoot {
                store_path_name: VALID_NAME.to_string(),
            }
        );
    }

    #[test]
    fn parse_subpath() {
        let path = format!("{VALID_NAME}/bin/rg");
        let r = parse_scheme_path(&path).unwrap();
        assert_eq!(
            r,
            ResolvedPath::SubPath {
                store_path_name: VALID_NAME.to_string(),
                subpath: "bin/rg".to_string(),
            }
        );
    }

    #[test]
    fn parse_deep_subpath() {
        let path = format!("{VALID_NAME}/share/man/man1/rg.1");
        let r = parse_scheme_path(&path).unwrap();
        assert_eq!(
            r,
            ResolvedPath::SubPath {
                store_path_name: VALID_NAME.to_string(),
                subpath: "share/man/man1/rg.1".to_string(),
            }
        );
    }

    #[test]
    fn parse_with_leading_trailing_slashes() {
        let path = format!("/{VALID_NAME}/bin/rg/");
        let r = parse_scheme_path(&path).unwrap();
        match r {
            ResolvedPath::SubPath {
                store_path_name,
                subpath,
            } => {
                assert_eq!(store_path_name, VALID_NAME);
                assert_eq!(subpath, "bin/rg");
            }
            _ => panic!("expected SubPath"),
        }
    }

    #[test]
    fn reject_path_traversal() {
        let path = format!("{VALID_NAME}/../etc/passwd");
        assert!(matches!(
            parse_scheme_path(&path),
            Err(ResolveError::PathTraversal(_))
        ));
    }

    #[test]
    fn reject_short_hash() {
        assert!(matches!(
            parse_scheme_path("abc-ripgrep"),
            Err(ResolveError::InvalidHash(_))
        ));
    }

    #[test]
    fn reject_invalid_nixbase32() {
        // 'e', 'o', 't', 'u' are NOT in nixbase32 alphabet
        let bad = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-bad";
        assert!(matches!(
            parse_scheme_path(bad),
            Err(ResolveError::InvalidHash(_))
        ));
    }

    #[test]
    fn reject_missing_separator() {
        let bad = "1b9jydsiygi6jhlz2dxbrxi6b4m1rn4rripgrep";
        assert!(matches!(
            parse_scheme_path(bad),
            Err(ResolveError::InvalidHash(_))
        ));
    }

    #[test]
    fn to_filesystem_path_root() {
        let p = to_filesystem_path(&ResolvedPath::Root, "/nix/store");
        assert_eq!(p, Some(PathBuf::from("/nix/store")));
    }

    #[test]
    fn to_filesystem_path_store_path() {
        let p = to_filesystem_path(
            &ResolvedPath::StorePathRoot {
                store_path_name: VALID_NAME.to_string(),
            },
            "/nix/store",
        );
        assert_eq!(
            p,
            Some(PathBuf::from(format!("/nix/store/{VALID_NAME}")))
        );
    }

    #[test]
    fn to_filesystem_path_subpath() {
        let p = to_filesystem_path(
            &ResolvedPath::SubPath {
                store_path_name: VALID_NAME.to_string(),
                subpath: "bin/rg".to_string(),
            },
            "/nix/store",
        );
        assert_eq!(
            p,
            Some(PathBuf::from(format!("/nix/store/{VALID_NAME}/bin/rg")))
        );
    }

    #[test]
    fn nixbase32_validation() {
        // Valid chars
        for c in "0123456789abcdfghijklmnpqrsvwxyz".chars() {
            assert!(is_nixbase32(c), "should be valid: {c}");
        }
        // Invalid chars
        for c in "eotu".chars() {
            assert!(!is_nixbase32(c), "should be invalid: {c}");
        }
        // Uppercase not valid
        assert!(!is_nixbase32('A'));
    }
}
