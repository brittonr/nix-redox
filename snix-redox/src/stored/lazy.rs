//! Lazy NAR extraction for the store scheme daemon.
//!
//! When a store path is registered but not yet extracted to the filesystem,
//! this module decompresses the cached NAR on first access. On Redox, all
//! filesystem operations use the pre-opened root fd pattern so extraction can
//! proceed after `setrens(0, 0)` without routing through initnsmgr.

use std::collections::HashSet;
use std::fs;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;
use sha2::{Digest, Sha256};

use crate::nar::{self, ManifestEntry};

/// Errors from lazy extraction.
#[derive(Debug)]
pub enum ExtractError {
    /// Store path not found in PathInfoDb / daemon metadata.
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

/// Result of an extraction attempt.
#[derive(Debug, Clone, Default)]
pub struct ExtractionOutcome {
    /// True when this call performed the extraction work.
    pub extracted_now: bool,
    /// Manifest returned for a freshly extracted store path.
    pub manifest: Option<Vec<ManifestEntry>>,
}

/// Ensure a store path is extracted to the filesystem.
///
/// If the store path already exists, returns immediately. If not, finds the
/// NAR in the cache, decompresses, extracts, verifies the hash, and returns
/// the manifest collected during extraction.
pub fn ensure_extracted(
    store_path_name: &str,
    store_dir: &str,
    cache_path: &str,
    expected_nar_hash: &str,
    extracting: &Mutex<HashSet<String>>,
    root_fd: Option<usize>,
) -> Result<ExtractionOutcome, ExtractError> {
    let dest = PathBuf::from(store_dir).join(store_path_name);

    // Fast path: already extracted.
    if path_exists(&dest, root_fd)? {
        return Ok(ExtractionOutcome::default());
    }

    {
        let mut set = extracting
            .lock()
            .map_err(|e| ExtractError::Io(format!("lock poisoned: {e}")))?;

        if set.contains(store_path_name) {
            drop(set);
            wait_for_extraction(&dest, root_fd)?;
            return Ok(ExtractionOutcome::default());
        }

        set.insert(store_path_name.to_string());
    }

    let result = do_extraction(
        store_path_name,
        store_dir,
        cache_path,
        expected_nar_hash,
        root_fd,
    );

    {
        let mut set = extracting
            .lock()
            .map_err(|e| ExtractError::Io(format!("lock poisoned: {e}")))?;
        set.remove(store_path_name);
    }

    result.map(|manifest| ExtractionOutcome {
        extracted_now: true,
        manifest: Some(manifest),
    })
}

fn wait_for_extraction(dest: &Path, root_fd: Option<usize>) -> Result<(), ExtractError> {
    for _ in 0..6000 {
        if path_exists(dest, root_fd)? {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    Err(ExtractError::Io(format!(
        "timed out waiting for extraction: {}",
        dest.display()
    )))
}

fn do_extraction(
    store_path_name: &str,
    store_dir: &str,
    cache_path: &str,
    expected_nar_hash: &str,
    root_fd: Option<usize>,
) -> Result<Vec<ManifestEntry>, ExtractError> {
    let abs_store_path = format!("{store_dir}/{store_path_name}");

    let sp = StorePath::<String>::from_absolute_path(abs_store_path.as_bytes())
        .map_err(|e| ExtractError::NotRegistered(format!("invalid store path: {e}")))?;
    let cache_key = nixbase32::encode(sp.digest());

    let (nar_path, file) = open_cached_nar(cache_path, &cache_key, root_fd)?;

    eprintln!(
        "stored: extracting {} from {}",
        store_path_name,
        nar_path.display()
    );

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
            _ => Box::new(reader),
        };

    let mut hashing = HashingExtractReader::new(decompressed);
    let mut buf_reader = BufReader::new(&mut hashing);

    #[cfg(target_os = "redox")]
    let manifest = if let Some(rfd) = root_fd {
        ensure_dir_exists(Path::new(store_dir), Some(rfd))
            .map_err(|e| ExtractError::Io(format!("creating {store_dir}: {e}")))?;
        nar::extract_with_manifest_via_root_fd(&mut buf_reader, &abs_store_path, rfd)
            .map_err(|e| ExtractError::Io(format!("NAR extraction: {e}")))?
    } else {
        fs::create_dir_all(store_dir)
            .map_err(|e| ExtractError::Io(format!("creating {store_dir}: {e}")))?;
        nar::extract_with_manifest(&mut buf_reader, &abs_store_path)
            .map_err(|e| ExtractError::Io(format!("NAR extraction: {e}")))?
    };

    #[cfg(not(target_os = "redox"))]
    let manifest = {
        let _ = root_fd;
        fs::create_dir_all(store_dir)
            .map_err(|e| ExtractError::Io(format!("creating {store_dir}: {e}")))?;
        nar::extract_with_manifest(&mut buf_reader, &abs_store_path)
            .map_err(|e| ExtractError::Io(format!("NAR extraction: {e}")))?
    };

    let actual_hash = hashing.finalize_hex();
    let expected_hash = normalize_hash(expected_nar_hash);

    if actual_hash != expected_hash {
        cleanup_failed_extraction(&abs_store_path, &manifest, root_fd);
        return Err(ExtractError::HashMismatch {
            store_path: abs_store_path,
            expected: expected_hash,
            actual: actual_hash,
        });
    }

    eprintln!("stored: extracted {} (hash verified)", store_path_name);
    Ok(manifest)
}

fn open_cached_nar(
    cache_path: &str,
    hash: &str,
    root_fd: Option<usize>,
) -> Result<(PathBuf, fs::File), ExtractError> {
    let narinfo = read_cached_narinfo(cache_path, hash, root_fd)?;

    #[cfg(target_os = "redox")]
    if let Some(rfd) = root_fd {
        return open_cached_nar_via_root_fd(cache_path, &narinfo.url, rfd);
    }

    #[cfg(not(target_os = "redox"))]
    let _ = root_fd;

    let nar_path = PathBuf::from(cache_path).join(&*narinfo.url);
    let file = fs::File::open(&nar_path)
        .map_err(|e| ExtractError::Io(format!("opening {}: {e}", nar_path.display())))?;
    Ok((nar_path, file))
}

fn read_cached_narinfo(
    cache_path: &str,
    hash: &str,
    root_fd: Option<usize>,
) -> Result<nix_compat::narinfo::NarInfo<'static>, ExtractError> {
    let narinfo_path = PathBuf::from(cache_path).join(format!("{hash}.narinfo"));

    #[cfg(target_os = "redox")]
    let body = if let Some(rfd) = root_fd {
        use std::io::Read;
        use std::os::unix::io::FromRawFd;

        let fd = raw_openat(&narinfo_path, rfd, syscall::O_RDONLY)
            .map_err(|_| ExtractError::NarNotFound(narinfo_path.display().to_string()))?;
        let mut file = unsafe { fs::File::from_raw_fd(fd as i32) };
        let mut body = String::new();
        file.read_to_string(&mut body)
            .map_err(|e| ExtractError::Io(format!("reading {}: {e}", narinfo_path.display())))?;
        body
    } else {
        fs::read_to_string(&narinfo_path)
            .map_err(|e| ExtractError::NarNotFound(format!("{}: {e}", narinfo_path.display())))?
    };

    #[cfg(not(target_os = "redox"))]
    let body = {
        let _ = root_fd;
        fs::read_to_string(&narinfo_path)
            .map_err(|e| ExtractError::NarNotFound(format!("{}: {e}", narinfo_path.display())))?
    };

    let body_static: &'static str = Box::leak(body.into_boxed_str());
    nix_compat::narinfo::NarInfo::parse(body_static)
        .map_err(|e| ExtractError::Io(format!("parsing {}: {e}", narinfo_path.display())))
}

#[cfg(target_os = "redox")]
fn open_cached_nar_via_root_fd(
    cache_path: &str,
    nar_relative_url: &str,
    root_fd: usize,
) -> Result<(PathBuf, fs::File), ExtractError> {
    use std::os::unix::io::FromRawFd;

    let path = PathBuf::from(cache_path).join(nar_relative_url);
    let fd = raw_openat(&path, root_fd, syscall::O_RDONLY)
        .map_err(|_| ExtractError::NarNotFound(path.display().to_string()))?;
    let file = unsafe { fs::File::from_raw_fd(fd as i32) };
    Ok((path, file))
}

fn path_exists(path: &Path, root_fd: Option<usize>) -> Result<bool, ExtractError> {
    #[cfg(target_os = "redox")]
    if let Some(rfd) = root_fd {
        return match raw_openat(path, rfd, syscall::O_STAT) {
            Ok(fd) => {
                let _ = syscall::close(fd);
                Ok(true)
            }
            Err(_) => Ok(false),
        };
    }

    #[cfg(not(target_os = "redox"))]
    let _ = root_fd;

    Ok(path.exists())
}

fn ensure_dir_exists(path: &Path, root_fd: Option<usize>) -> std::io::Result<()> {
    #[cfg(target_os = "redox")]
    if let Some(rfd) = root_fd {
        return raw_mkdir_p(path, rfd);
    }

    #[cfg(not(target_os = "redox"))]
    let _ = root_fd;

    fs::create_dir_all(path)
}

fn cleanup_failed_extraction(abs_store_path: &str, manifest: &[ManifestEntry], root_fd: Option<usize>) {
    #[cfg(target_os = "redox")]
    if let Some(rfd) = root_fd {
        let _ = remove_tree_via_manifest(abs_store_path, manifest, rfd);
        return;
    }

    #[cfg(not(target_os = "redox"))]
    let _ = root_fd;

    let _ = fs::remove_dir_all(abs_store_path);
}

/// Find a NAR file in the cache directory.
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

fn normalize_hash(hash: &str) -> String {
    if let Some(hex) = hash.strip_prefix("sha256:") {
        hex.to_string()
    } else {
        hash.to_string()
    }
}

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

#[cfg(target_os = "redox")]
fn raw_openat(path: &Path, root_fd: usize, flags: usize) -> std::io::Result<usize> {
    let clean = path
        .to_string_lossy()
        .trim_start_matches('/')
        .to_string();
    let fcntl_flags = flags & syscall::O_FCNTL_MASK;
    unsafe {
        syscall::syscall5(
            syscall::SYS_OPENAT,
            root_fd,
            clean.as_ptr() as usize,
            clean.len(),
            flags,
            fcntl_flags,
        )
    }
    .map_err(|e| std::io::Error::new(std::io::ErrorKind::NotFound, format!("SYS_OPENAT: {e}")))
}

#[cfg(target_os = "redox")]
fn raw_mkdir_p(path: &Path, root_fd: usize) -> std::io::Result<()> {
    let clean = path
        .to_string_lossy()
        .trim_start_matches('/')
        .to_string();
    let mut built = String::new();
    for component in clean.split('/') {
        if component.is_empty() {
            continue;
        }
        if !built.is_empty() {
            built.push('/');
        }
        built.push_str(component);
        let flags = syscall::O_CREAT | syscall::O_DIRECTORY;
        let fd = unsafe {
            syscall::syscall5(
                syscall::SYS_OPENAT,
                root_fd,
                built.as_ptr() as usize,
                built.len(),
                flags,
                flags & syscall::O_FCNTL_MASK,
            )
        }
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("mkdir {built}: {e}")))?;
        let _ = syscall::close(fd);
    }
    Ok(())
}

#[cfg(target_os = "redox")]
fn remove_tree_via_manifest(
    abs_store_path: &str,
    manifest: &[ManifestEntry],
    root_fd: usize,
) -> std::io::Result<()> {
    for entry in manifest.iter().rev() {
        let path = PathBuf::from(abs_store_path).join(&entry.path);
        let clean = path.to_string_lossy().trim_start_matches('/').to_string();
        let flags = if entry.entry_type == "dir" {
            syscall::AT_REMOVEDIR
        } else {
            0
        };
        let _ = syscall::unlinkat(root_fd, &clean, flags);
    }

    let clean_root = abs_store_path.trim_start_matches('/');
    let _ = syscall::unlinkat(root_fd, clean_root, syscall::AT_REMOVEDIR);
    Ok(())
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_nar_file_zst_preferred() {
        let tmp = tempfile::tempdir().unwrap();
        let hash = "1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r";

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
        assert_eq!(normalize_hash("sha256:abcdef1234"), "abcdef1234");
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
