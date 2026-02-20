//! Binary cache client — fetch store paths from cache.nixos.org (or any Nix binary cache).
//!
//! Protocol:
//!   1. GET /{hash}.narinfo → NarInfo metadata (store path, NAR hash, URL, compression)
//!   2. GET /nar/{hash}.nar.{compression} → compressed NAR file
//!   3. Decompress → NAR reader → extract to /nix/store/
//!
//! Supports single-path and recursive (full closure) fetching.
//! Uses nix-compat for NarInfo parsing and NAR reading (sync).
//! Uses ureq for HTTP (sync, no tokio).

use std::collections::{BTreeSet, VecDeque};
use std::io::{self, BufReader, Read};

use nix_compat::narinfo::NarInfo;
use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;
use sha2::{Digest, Sha256};

use crate::nar;
use crate::pathinfo::PathInfoDb;
use crate::store;

/// Fetch and display narinfo for a store path.
pub fn path_info(
    store_path_str: &str,
    cache_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let sp = StorePath::<String>::from_absolute_path(store_path_str.as_bytes())?;
    let narinfo = fetch_narinfo(&sp, cache_url)?;

    println!("StorePath: {}", sp.to_absolute_path());
    println!("URL:       {}", narinfo.url);
    println!(
        "NarHash:   sha256:{}",
        data_encoding::HEXLOWER.encode(&narinfo.nar_hash)
    );
    println!("NarSize:   {}", narinfo.nar_size);
    if let Some(comp) = narinfo.compression {
        println!("Compression: {comp}");
    }
    if let Some(fh) = narinfo.file_hash {
        println!(
            "FileHash:  sha256:{}",
            data_encoding::HEXLOWER.encode(&fh)
        );
    }
    if let Some(fs) = narinfo.file_size {
        println!("FileSize:  {fs}");
    }
    println!("References:");
    for r in &narinfo.references {
        println!("  {}", r.to_absolute_path());
    }
    if !narinfo.signatures.is_empty() {
        println!("Signatures:");
        for sig in &narinfo.signatures {
            println!("  {sig}");
        }
    }

    Ok(())
}

/// Fetch a single store path from a binary cache and install it.
///
/// Downloads the NAR, decompresses it, extracts to /nix/store/,
/// verifies the hash, and optionally registers the path.
pub fn fetch(
    store_path_str: &str,
    cache_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    fetch_inner(store_path_str, cache_url, None)
}

/// Recursively fetch a store path and all its transitive dependencies.
///
/// Uses BFS to discover and download the full closure. Each fetched
/// path is registered in the PathInfo database so closures and GC work.
pub fn fetch_recursive(
    store_path_str: &str,
    cache_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let db = PathInfoDb::open()?;

    let mut queue: VecDeque<String> = VecDeque::new();
    let mut visited: BTreeSet<String> = BTreeSet::new();
    let mut fetched_count: u32 = 0;
    let mut skipped_count: u32 = 0;
    let mut total_nar_size: u64 = 0;

    queue.push_back(store_path_str.to_string());

    while let Some(path) = queue.pop_front() {
        if visited.contains(&path) {
            continue;
        }
        visited.insert(path.clone());

        // Check if already present locally
        let already_present = std::path::Path::new(&path).exists();
        let already_registered = db.is_registered(&path);

        if already_present && already_registered {
            skipped_count += 1;
            eprintln!("✓ already present: {path}");

            // Still need to follow references for completeness
            if let Some(info) = db.get(&path)? {
                for r in &info.references {
                    if !visited.contains(r) {
                        queue.push_back(r.clone());
                    }
                }
            }
            continue;
        }

        // Fetch narinfo first (we need references even if present on disk)
        let sp = StorePath::<String>::from_absolute_path(path.as_bytes())?;
        let narinfo = match fetch_narinfo(&sp, cache_url) {
            Ok(ni) => ni,
            Err(e) => {
                return Err(
                    format!("failed to fetch narinfo for {path}: {e}").into()
                );
            }
        };

        // Extract references and enqueue them
        let references: Vec<String> = narinfo
            .references
            .iter()
            .map(|r| r.to_absolute_path())
            .collect();

        for r in &references {
            if !visited.contains(r) {
                queue.push_back(r.clone());
            }
        }

        // Download and extract if not already on disk
        if !already_present {
            fetch_inner(&path, cache_url, Some(&db))?;
        } else if !already_registered {
            // Present on disk but not registered — register it
            let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
            let signatures: Vec<String> =
                narinfo.signatures.iter().map(|s| s.to_string()).collect();
            store::register_path(
                &db,
                &path,
                &nar_hash_hex,
                narinfo.nar_size,
                references.clone(),
                signatures,
            )?;
            eprintln!("✓ registered: {path}");
            skipped_count += 1;
        }

        total_nar_size += narinfo.nar_size;
        fetched_count += 1;
    }

    eprintln!();
    eprintln!(
        "Done: {} fetched, {} already present, {} total NAR size",
        fetched_count,
        skipped_count,
        human_size(total_nar_size),
    );

    Ok(())
}

/// Inner fetch that optionally registers the path.
///
/// If `db` is `Some`, the path is registered after successful extraction.
/// If `db` is `None`, the path is just extracted (legacy single-fetch mode).
fn fetch_inner(
    store_path_str: &str,
    cache_url: &str,
    db: Option<&PathInfoDb>,
) -> Result<(), Box<dyn std::error::Error>> {
    let sp = StorePath::<String>::from_absolute_path(store_path_str.as_bytes())?;
    let dest = sp.to_absolute_path();

    // Check if already present
    if std::path::Path::new(&dest).exists() {
        eprintln!("already exists: {dest}");
        return Ok(());
    }

    // Ensure /nix/store exists
    store::ensure_store_dir()?;

    // Fetch narinfo
    eprintln!("fetching narinfo for {}...", sp.to_absolute_path());
    let narinfo = fetch_narinfo(&sp, cache_url)?;

    // Fetch the NAR
    let nar_url = format!("{}/{}", cache_url.trim_end_matches('/'), narinfo.url);
    eprintln!("downloading {}...", narinfo.url);

    let resp = ureq::get(&nar_url).call()?;
    let reader = resp.into_body().into_reader();

    // Decompress based on compression type (pure Rust decompressors)
    let decompressed: Box<dyn Read> = match narinfo.compression {
        None | Some("none") => Box::new(reader),
        Some("xz") => {
            let mut input = io::BufReader::new(reader);
            let mut output = Vec::new();
            lzma_rs::xz_decompress(&mut input, &mut output)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("xz: {e}")))?;
            Box::new(io::Cursor::new(output))
        }
        Some("zstd") | Some("zst") => Box::new(
            ruzstd::decoding::StreamingDecoder::new(reader)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("zstd: {e}")))?,
        ),
        Some("bzip2") | Some("bz2") => Box::new(bzip2_rs::DecoderReader::new(reader)),
        Some(other) => return Err(format!("unsupported compression: {other}").into()),
    };

    // Verify NAR hash while extracting
    let mut hashing_reader = HashingReader::new(SendReader(decompressed));
    let mut buf_reader = BufReader::new(&mut hashing_reader);

    // Extract NAR to store path
    eprintln!("extracting to {dest}...");
    nar::extract(&mut buf_reader, &dest)?;

    // Verify hash
    let actual_hash = hashing_reader.finalize();
    if actual_hash != narinfo.nar_hash {
        // Clean up on hash mismatch
        let _ = std::fs::remove_dir_all(&dest);
        return Err(format!(
            "NAR hash mismatch!\n  expected: {}\n  got:      {}",
            data_encoding::HEXLOWER.encode(&narinfo.nar_hash),
            data_encoding::HEXLOWER.encode(&actual_hash),
        )
        .into());
    }

    // Register in PathInfo database if provided
    if let Some(db) = db {
        let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
        let references: Vec<String> = narinfo
            .references
            .iter()
            .map(|r| r.to_absolute_path())
            .collect();
        let signatures: Vec<String> =
            narinfo.signatures.iter().map(|s| s.to_string()).collect();

        store::register_path(db, &dest, &nar_hash_hex, narinfo.nar_size, references, signatures)?;
    }

    eprintln!("✓ verified and installed: {dest}");
    Ok(())
}

/// Fetch narinfo from binary cache.
fn fetch_narinfo(
    sp: &StorePath<String>,
    cache_url: &str,
) -> Result<NarInfo<'static>, Box<dyn std::error::Error>> {
    let hash = nixbase32::encode(sp.digest());
    let url = format!("{}/{}.narinfo", cache_url.trim_end_matches('/'), hash);

    let resp = ureq::get(&url).call()?;
    let body = resp.into_body().read_to_string()?;

    // NarInfo::parse borrows from the input string, so we need to leak it
    // to get a 'static lifetime. This is fine for a CLI tool.
    let body_static: &'static str = Box::leak(body.into_boxed_str());

    let narinfo = NarInfo::parse(body_static)?;
    Ok(narinfo)
}

// ===== Helpers =====

/// Wrapper to make a reader also Send (ureq readers are Send).
struct SendReader<R>(R);

impl<R: Read> Read for SendReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.read(buf)
    }
}

unsafe impl<R: Read> Send for SendReader<R> {}

/// Reader wrapper that hashes content as it's read.
struct HashingReader<R> {
    inner: R,
    hasher: Sha256,
}

impl<R: Read> HashingReader<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
        }
    }

    fn finalize(self) -> [u8; 32] {
        self.hasher.finalize().into()
    }
}

impl<R: Read> Read for HashingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        if n > 0 {
            self.hasher.update(&buf[..n]);
        }
        Ok(n)
    }
}

/// Format bytes as human-readable size.
fn human_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;

    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{bytes} B")
    }
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn hashing_reader_empty() {
        let data = Cursor::new(vec![]);
        let reader = HashingReader::new(data);
        let hash = reader.finalize();

        let expected = Sha256::digest(b"");
        assert_eq!(hash, expected.as_slice());
    }

    #[test]
    fn hashing_reader_hello() {
        let data = Cursor::new(b"hello world");
        let mut reader = HashingReader::new(data);

        let mut buf = vec![0u8; 1024];
        let _ = reader.read(&mut buf).unwrap();

        let hash = reader.finalize();
        let expected = Sha256::digest(b"hello world");
        assert_eq!(hash, expected.as_slice());
    }

    #[test]
    fn hashing_reader_incremental() {
        let data = Cursor::new(b"hello world");
        let mut reader = HashingReader::new(data);

        let mut chunk1 = [0u8; 5];
        let mut chunk2 = [0u8; 6];

        let n1 = reader.read(&mut chunk1).unwrap();
        let n2 = reader.read(&mut chunk2).unwrap();

        assert_eq!(n1, 5);
        assert_eq!(n2, 6);

        let hash = reader.finalize();
        let expected = Sha256::digest(b"hello world");
        assert_eq!(hash, expected.as_slice());
    }

    #[test]
    fn hashing_reader_zero_byte_read() {
        let data = Cursor::new(b"test");
        let mut reader = HashingReader::new(data);

        let mut buf = [];
        let n = reader.read(&mut buf).unwrap();
        assert_eq!(n, 0);

        let mut buf = [0u8; 4];
        let n = reader.read(&mut buf).unwrap();
        assert_eq!(n, 4);

        let hash = reader.finalize();
        let expected = Sha256::digest(b"test");
        assert_eq!(hash, expected.as_slice());
    }

    #[test]
    fn send_reader_read() {
        let data = Cursor::new(b"hello");
        let mut reader = SendReader(data);

        let mut buf = [0u8; 5];
        let n = reader.read(&mut buf).unwrap();

        assert_eq!(n, 5);
        assert_eq!(&buf, b"hello");
    }

    #[test]
    fn send_reader_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<SendReader<Cursor<Vec<u8>>>>();
    }

    #[test]
    fn narinfo_url_construction() {
        let store_path = "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-hello-1.0";
        let sp = StorePath::<String>::from_absolute_path(store_path.as_bytes()).unwrap();
        let hash = nixbase32::encode(sp.digest());

        let cache_url = "https://cache.nixos.org";
        let url = format!("{}/{}.narinfo", cache_url.trim_end_matches('/'), hash);

        assert!(url.starts_with("https://cache.nixos.org/"));
        assert!(url.ends_with(".narinfo"));
        assert_eq!(hash, "00bgd045z0d4icpbc2yyz4gx48ak44la");
    }

    #[test]
    fn store_path_parsing() {
        let valid = "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-hello-1.0";
        assert!(StorePath::<String>::from_absolute_path(valid.as_bytes()).is_ok());

        let invalid_paths: Vec<&str> = vec![
            "/invalid/path",
            "/nix/store/",
            "not-absolute",
            "/nix/store/tooshort-hello",
        ];

        for path in invalid_paths {
            assert!(StorePath::<String>::from_absolute_path(path.as_bytes()).is_err());
        }

        let toolong =
            "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-".to_string() + &"x".repeat(300);
        assert!(StorePath::<String>::from_absolute_path(toolong.as_bytes()).is_err());
    }

    #[test]
    fn xz_decompression_roundtrip() {
        let original = b"test data for xz compression";

        let mut compressed = Vec::new();
        lzma_rs::xz_compress(&mut &original[..], &mut compressed).unwrap();

        let mut decompressed = Vec::new();
        lzma_rs::xz_decompress(&mut &compressed[..], &mut decompressed).unwrap();

        assert_eq!(decompressed, original);
    }

    #[test]
    fn bzip2_decompression() {
        let compressed = vec![
            0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x19, 0x31, 0x65, 0x3d,
            0x00, 0x00, 0x00, 0x81, 0x00, 0x02, 0x44, 0xa0, 0x00, 0x21, 0x9a, 0x68, 0x33, 0x4d,
            0x07, 0x33, 0x8b, 0xb9, 0x22, 0x9c, 0x28, 0x48, 0x0c, 0x98, 0xb2, 0x9e, 0x80,
        ];

        let mut decompressor = bzip2_rs::DecoderReader::new(&compressed[..]);
        let mut decompressed = Vec::new();
        decompressor.read_to_end(&mut decompressed).unwrap();

        assert_eq!(decompressed, b"hello");
    }

    #[test]
    fn human_size_formatting() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(1023), "1023 B");
        assert_eq!(human_size(1024), "1.0 KB");
        assert_eq!(human_size(1048576), "1.0 MB");
        assert_eq!(human_size(1073741824), "1.0 GB");
    }
}
