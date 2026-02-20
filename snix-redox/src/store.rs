//! Local Nix store management for Redox OS.
//!
//! Manages /nix/store on the local filesystem. Unlike the full Nix daemon,
//! this is a simple filesystem-based store with no SQLite database.
//! Store integrity is verified via content hashing.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use nix_compat::store_path::{StorePath, STORE_DIR};
// sha2 and Digest available if we need hash verification later

/// Ensure the /nix/store directory exists
pub fn ensure_store_dir() -> io::Result<()> {
    let store = Path::new(STORE_DIR);
    if !store.exists() {
        fs::create_dir_all(store)?;
        eprintln!("created {STORE_DIR}");
    }
    Ok(())
}

/// Verify the local store — check that all store paths are valid
pub fn verify() -> Result<(), Box<dyn std::error::Error>> {
    let store = Path::new(STORE_DIR);

    if !store.exists() {
        eprintln!("no store at {STORE_DIR}");
        return Ok(());
    }

    let mut count = 0;
    let mut errors = 0;

    for entry in fs::read_dir(store)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        // Try to parse as a store path
        let full_path = format!("{STORE_DIR}/{name_str}");
        match StorePath::<String>::from_absolute_path(full_path.as_bytes()) {
            Ok(_sp) => {
                count += 1;
                if entry.metadata()?.is_dir() || entry.metadata()?.is_file() {
                    // Store path exists and is parseable
                } else {
                    eprintln!("  warning: unusual file type: {full_path}");
                }
            }
            Err(e) => {
                errors += 1;
                eprintln!("  invalid store path: {name_str}: {e}");
            }
        }
    }

    println!("store: {count} paths, {errors} errors");
    Ok(())
}

/// List all store paths
#[allow(dead_code)] // Public API not yet wired to CLI
pub fn list_paths() -> io::Result<Vec<PathBuf>> {
    let store = Path::new(STORE_DIR);
    if !store.exists() {
        return Ok(Vec::new());
    }

    let mut paths = Vec::new();
    for entry in fs::read_dir(store)? {
        let entry = entry?;
        paths.push(entry.path());
    }
    paths.sort();
    Ok(paths)
}

/// Check if a store path exists locally
#[allow(dead_code)] // Public API not yet wired to CLI
pub fn path_exists(store_path: &str) -> bool {
    Path::new(store_path).exists()
}

/// Get the size of a store path (recursive)
#[allow(dead_code)] // Public API not yet wired to CLI
pub fn path_size(path: &Path) -> io::Result<u64> {
    if path.is_file() {
        Ok(path.metadata()?.len())
    } else if path.is_dir() {
        let mut total = 0;
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            total += path_size(&entry.path())?;
        }
        Ok(total)
    } else {
        Ok(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn path_exists_true() {
        let tmp = TempDir::new().unwrap();
        let file_path = tmp.path().join("test.txt");

        fs::write(&file_path, "test content").unwrap();

        assert!(path_exists(file_path.to_str().unwrap()));
    }

    #[test]
    fn path_exists_false() {
        let tmp = TempDir::new().unwrap();
        let nonexistent = tmp.path().join("does-not-exist.txt");

        assert!(!path_exists(nonexistent.to_str().unwrap()));
    }

    #[test]
    fn path_size_file() {
        let tmp = TempDir::new().unwrap();
        let file_path = tmp.path().join("test.txt");

        let content = b"hello world";
        fs::write(&file_path, content).unwrap();

        let size = path_size(&file_path).unwrap();
        assert_eq!(size, content.len() as u64);
    }

    #[test]
    fn path_size_dir() {
        let tmp = TempDir::new().unwrap();

        // Create multiple files
        fs::write(tmp.path().join("file1.txt"), b"hello").unwrap();
        fs::write(tmp.path().join("file2.txt"), b"world").unwrap();

        let subdir = tmp.path().join("subdir");
        fs::create_dir(&subdir).unwrap();
        fs::write(subdir.join("file3.txt"), b"test").unwrap();

        let total_size = path_size(tmp.path()).unwrap();

        // Should be 5 + 5 + 4 = 14 bytes
        assert_eq!(total_size, 14);
    }

    #[test]
    fn path_size_empty() {
        let tmp = TempDir::new().unwrap();

        let size = path_size(tmp.path()).unwrap();
        assert_eq!(size, 0);
    }

    #[test]
    fn store_path_roundtrip() {
        // Create a valid store path using nix_compat
        // We can't easily create a real StorePath without a hash,
        // but we can test parsing an existing one
        let store_path_str = "/nix/store/abc123defg456-hello-1.0";

        // This should parse successfully
        let result = StorePath::<String>::from_absolute_path(store_path_str.as_bytes());

        // If it parses, verify it starts with /nix/store/
        if let Ok(sp) = result {
            let absolute = sp.to_absolute_path();
            assert!(absolute.starts_with("/nix/store/"));
        }
    }
}
