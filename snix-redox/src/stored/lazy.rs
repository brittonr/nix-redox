//! Lazy NAR extraction for the store scheme daemon.
//!
//! When a store path is registered in PathInfoDb but not yet extracted
//! to the filesystem, this module handles the decompression and extraction
//! on first access. The extraction is atomic from the perspective of
//! concurrent accessors: a mutex tracks which store paths are currently
//! being extracted, and concurrent openers block until extraction completes.

use std::collections::HashSet;
use std::fs;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;
use sha2::{Digest, Sha256};

use crate::nar;
use crate::pathinfo::PathInfoDb;

/// Errors from lazy extraction.
#[derive(Debug)]
pub enum ExtractError {
    /// Store path not found in PathInfoDb.
    NotRegistered(String),
    /// NAR file not found in cache.
    NarNotFound(String),
    /// NAR hash mismatch after extraction.
    HashMismatch {
        store_path: String,
        expected: String,
        actual: String,
    },
    /// I/O error during extraction.
    Io(String),
}

impl std::fmt::Display for ExtractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotRegistered(p) => write!(f, "store path not registered: {p}"),
            Self::NarNotFound(p) => write!(f, "NAR file not found in cache: {p}"),
            Self::HashMismatch {
                store_path,
                expected,
                actual,
            } => write!(
                f,
                "NAR hash mismatch for {store_path}: expected {expected}, got {actual}"
            ),
            Self::Io(msg) => write!(f, "extraction I/O error: {msg}"),
        }
    }
}

impl std::error::Error for ExtractError {}

/// Ensure a store path is extracted to the filesystem.
///
/// If the store path directory already exists, returns immediately.
/// If not, finds the NAR in the cache, decompresses, extracts, and verifies.
///
/// The `extracting` mutex tracks in-progress extractions to prevent
/// concurrent extraction of the same store path. Callers blocked on an
/// in-progress extraction will find the directory exists when the mutex
/// is released, and return immediately.
pub fn ensure_extracted(
    store_path_name: &str,
    store_dir: &str,
    cache_path: &str,
    db: &PathInfoDb,
    extracting: &Mutex<HashSet<String>>,
) -> Result<(), ExtractError> {
    let dest = PathBuf::from(store_dir).join(store_path_name);

    // Fast path: already extracted.
    if dest.exists() {
        return Ok(());
    }

    // Acquire extraction lock for this specific store path.
    // This ensures only one thread extracts a given path at a time.
    {
        let mut set = extracting
            .lock()
            .map_err(|e| ExtractError::Io(format!("lock poisoned: {e}")))?;

        if set.contains(store_path_name) {
            // Another thread is already extracting this path.
            // Drop the lock and spin-wait for it to finish.
            drop(set);
            wait_for_extraction(&dest)?;
            return Ok(());
        }

        set.insert(store_path_name.to_string());
    }

    // We hold the extraction claim. Do the work, then release.
    let result = do_extraction(store_path_name, store_dir, cache_path, db);

    // Always release the extraction claim.
    {
        let mut set = extracting
            .lock()
            .map_err(|e| ExtractError::Io(format!("lock poisoned: {e}")))?;
        set.remove(store_path_name);
    }

    result
}

/// Spin-wait for another thread's extraction to complete.
fn wait_for_extraction(dest: &Path) -> Result<(), ExtractError> {
    // Simple poll: check if the directory exists.
    // In practice, extractions are fast (< 1s for most packages).
    for _ in 0..6000 {
        if dest.exists() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    Err(ExtractError::Io(format!(
        "timed out waiting for extraction: {}",
        dest.display()
    )))
}

/// Actually extract a NAR from the cache to the store.
fn do_extraction(
    store_path_name: &str,
    store_dir: &str,
    cache_path: &str,
    db: &PathInfoDb,
) -> Result<(), ExtractError> {
    let abs_store_path = format!("{store_dir}/{store_path_name}");

    // Look up the store path in PathInfoDb.
    let info = db
        .get(&abs_store_path)
        .map_err(|e| ExtractError::Io(format!("pathinfo lookup: {e}")))?
        .ok_or_else(|| ExtractError::NotRegistered(abs_store_path.clone()))?;

    // Compute the nixbase32 hash for narinfo/NAR file lookup.
    let sp = StorePath::<String>::from_absolute_path(abs_store_path.as_bytes())
        .map_err(|e| ExtractError::Io(format!("invalid store path: {e}")))?;
    let hash = nixbase32::encode(sp.digest());

    // Try to find the NAR in the cache.
    // Check for: {hash}.nar.zst, {hash}.nar.xz, {hash}.nar.bz2, {hash}.nar
    let nar_path = find_nar_file(cache_path, &hash)
        .ok_or_else(|| ExtractError::NarNotFound(format!("{cache_path}/{hash}.nar*")))?;

    eprintln!(
        "stored: extracting {} from {}",
        store_path_name,
        nar_path.display()
    );

    // Open and decompress.
    let file = fs::File::open(&nar_path)
        .map_err(|e| ExtractError::Io(format!("opening {}: {e}", nar_path.display())))?;
    let reader = BufReader::new(file);

    let decompressed: Box<dyn std::io::Read + Send> =
        match nar_path.extension().and_then(|e| e.to_str()) {
            Some("zst") => Box::new(
                ruzstd::decoding::StreamingDecoder::new(reader)
                    .map_err(|e| ExtractError::Io(format!("zstd init: {e}")))?,
            ),
            Some("xz") => {
                let mut input = BufReader::new(reader);
                let mut output = Vec::new();
                lzma_rs::xz_decompress(&mut input, &mut output)
                    .map_err(|e| ExtractError::Io(format!("xz decompress: {e}")))?;
                Box::new(std::io::Cursor::new(output))
            }
            Some("bz2") => Box::new(bzip2_rs::DecoderReader::new(reader)),
            _ => Box::new(reader), // Assume uncompressed .nar
        };

    // Hash while reading for verification.
    let mut hashing = HashingExtractReader::new(decompressed);
    let mut buf_reader = BufReader::new(&mut hashing);

    // Ensure store directory exists.
    fs::create_dir_all(store_dir)
        .map_err(|e| ExtractError::Io(format!("creating {store_dir}: {e}")))?;

    // Extract.
    nar::extract(&mut buf_reader, &abs_store_path)
        .map_err(|e| ExtractError::Io(format!("NAR extraction: {e}")))?;

    // Verify hash.
    let actual_hash = hashing.finalize_hex();
    let expected_hash = normalize_hash(&info.nar_hash);

    if actual_hash != expected_hash {
        // Clean up failed extraction.
        let _ = fs::remove_dir_all(&abs_store_path);
        return Err(ExtractError::HashMismatch {
            store_path: abs_store_path,
            expected: expected_hash,
            actual: actual_hash,
        });
    }

    eprintln!("stored: extracted {} (hash verified)", store_path_name);
    Ok(())
}

/// Find a NAR file in the cache directory.
///
/// Checks for compressed variants in priority order:
/// `.nar.zst`, `.nar.xz`, `.nar.bz2`, `.nar`
fn find_nar_file(cache_path: &str, hash: &str) -> Option<PathBuf> {
    let base = PathBuf::from(cache_path);

    for ext in &["nar.zst", "nar.xz", "nar.bz2", "nar"] {
        let path = base.join(format!("{hash}.{ext}"));
        if path.exists() {
            return Some(path);
        }
    }

    None
}

/// Normalize a hash string for comparison.
///
/// PathInfoDb may store hashes as `sha256:abcdef...` (hex) or just hex.
/// Strip the algorithm prefix for comparison.
fn normalize_hash(hash: &str) -> String {
    if let Some(hex) = hash.strip_prefix("sha256:") {
        hex.to_string()
    } else {
        hash.to_string()
    }
}

/// Reader that SHA-256 hashes content as it's read.
struct HashingExtractReader<R> {
    inner: R,
    hasher: Sha256,
}

impl<R: std::io::Read> HashingExtractReader<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
        }
    }

    fn finalize_hex(self) -> String {
        format!("{:x}", self.hasher.finalize())
    }
}

impl<R: std::io::Read> std::io::Read for HashingExtractReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        if n > 0 {
            self.hasher.update(&buf[..n]);
        }
        Ok(n)
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_nar_file_zst_preferred() {
        let tmp = tempfile::tempdir().unwrap();
        let hash = "1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r";

        // Create multiple formats.
        fs::write(tmp.path().join(format!("{hash}.nar")), "raw").unwrap();
        fs::write(tmp.path().join(format!("{hash}.nar.zst")), "zst").unwrap();

        let found = find_nar_file(tmp.path().to_str().unwrap(), hash);
        assert!(found.is_some());
        assert!(found.unwrap().to_str().unwrap().ends_with(".nar.zst"));
    }

    #[test]
    fn find_nar_file_fallback_to_raw() {
        let tmp = tempfile::tempdir().unwrap();
        let hash = "1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r";

        fs::write(tmp.path().join(format!("{hash}.nar")), "raw").unwrap();

        let found = find_nar_file(tmp.path().to_str().unwrap(), hash);
        assert!(found.is_some());
        assert!(found.unwrap().to_str().unwrap().ends_with(".nar"));
    }

    #[test]
    fn find_nar_file_not_found() {
        let tmp = tempfile::tempdir().unwrap();
        let found = find_nar_file(tmp.path().to_str().unwrap(), "nonexistent");
        assert!(found.is_none());
    }

    #[test]
    fn normalize_hash_strips_prefix() {
        assert_eq!(
            normalize_hash("sha256:abcdef1234"),
            "abcdef1234"
        );
    }

    #[test]
    fn normalize_hash_no_prefix() {
        assert_eq!(normalize_hash("abcdef1234"), "abcdef1234");
    }

    #[test]
    fn hashing_reader_correct() {
        use std::io::{Cursor, Read};

        let data = b"hello world of lazy extraction";
        let expected = Sha256::digest(data);

        let cursor = Cursor::new(data.to_vec());
        let mut reader = HashingExtractReader::new(cursor);

        let mut buf = vec![0u8; 1024];
        let mut total = 0;
        loop {
            let n = reader.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            total += n;
        }
        assert_eq!(total, data.len());

        let hex = reader.finalize_hex();
        assert_eq!(hex, format!("{:x}", expected));
    }
}
