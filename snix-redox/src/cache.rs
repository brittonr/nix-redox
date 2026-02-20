//! Binary cache client — fetch store paths from cache.nixos.org (or any Nix binary cache).
//!
//! Protocol:
//!   1. GET /{hash}.narinfo → NarInfo metadata (store path, NAR hash, URL, compression)
//!   2. GET /nar/{hash}.nar.{compression} → compressed NAR file
//!   3. Decompress → NAR reader → extract to /nix/store/
//!
//! Uses nix-compat for NarInfo parsing and NAR reading (sync).
//! Uses ureq for HTTP (sync, no tokio).

use std::io::{self, Read, BufReader};

use nix_compat::narinfo::NarInfo;
use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;
use sha2::{Sha256, Digest};

/// Wrapper to make a reader also Send (ureq readers are Send)
struct SendReader<R>(R);
impl<R: Read> Read for SendReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> { self.0.read(buf) }
}
unsafe impl<R: Read> Send for SendReader<R> {}

use crate::nar;
use crate::store;

/// Fetch and display narinfo for a store path
pub fn path_info(
    store_path_str: &str,
    cache_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let sp = StorePath::<String>::from_absolute_path(store_path_str.as_bytes())?;
    let narinfo = fetch_narinfo(&sp, cache_url)?;

    println!("StorePath: {}", sp.to_absolute_path());
    println!("URL:       {}", narinfo.url);
    println!("NarHash:   sha256:{}", data_encoding::HEXLOWER.encode(&narinfo.nar_hash));
    println!("NarSize:   {}", narinfo.nar_size);
    if let Some(comp) = narinfo.compression {
        println!("Compression: {comp}");
    }
    if let Some(fh) = narinfo.file_hash {
        println!("FileHash:  sha256:{}", data_encoding::HEXLOWER.encode(&fh));
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

/// Fetch a store path from a binary cache and install it
pub fn fetch(
    store_path_str: &str,
    cache_url: &str,
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
    // xz uses lzma-rs's function API (no streaming reader), so we buffer it
    let decompressed: Box<dyn Read> = match narinfo.compression {
        None | Some("none") => Box::new(reader),
        Some("xz") => {
            // lzma-rs only has a function-based API, so buffer the decompressed output
            let mut input = io::BufReader::new(reader);
            let mut output = Vec::new();
            lzma_rs::xz_decompress(&mut input, &mut output)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("xz: {e}")))?;
            Box::new(io::Cursor::new(output))
        },
        Some("zstd") | Some("zst") => {
            Box::new(ruzstd::decoding::StreamingDecoder::new(reader)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("zstd: {e}")))?)
        },
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
        ).into());
    }

    eprintln!("✓ verified and installed: {dest}");
    Ok(())
}

/// Fetch narinfo from binary cache
fn fetch_narinfo<'a>(
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

/// Reader wrapper that hashes content as it's read
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn hashing_reader_empty() {
        let data = Cursor::new(vec![]);
        let reader = HashingReader::new(data);
        let hash = reader.finalize();

        // SHA256 of empty string
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
        // Read "hello world" in small chunks
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

        // Zero-length buffer should not panic
        let mut buf = [];
        let n = reader.read(&mut buf).unwrap();
        assert_eq!(n, 0);

        // Now read actual data
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
        // Compile-time test that SendReader implements Send
        fn assert_send<T: Send>() {}
        assert_send::<SendReader<Cursor<Vec<u8>>>>();
    }

    #[test]
    fn narinfo_url_construction() {
        // Test URL construction from a store path
        // Use a valid nixbase32 hash (32 chars from nixbase32 alphabet)
        let store_path = "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-hello-1.0";

        // Parse the store path
        let sp = StorePath::<String>::from_absolute_path(store_path.as_bytes()).unwrap();

        // Encode the digest with nixbase32
        let hash = nixbase32::encode(sp.digest());

        // Verify URL format
        let cache_url = "https://cache.nixos.org";
        let url = format!("{}/{}.narinfo", cache_url.trim_end_matches('/'), hash);

        assert!(url.starts_with("https://cache.nixos.org/"));
        assert!(url.ends_with(".narinfo"));
        assert_eq!(hash, "00bgd045z0d4icpbc2yyz4gx48ak44la");
    }

    #[test]
    fn store_path_parsing() {
        // Valid store path (nixbase32 hash is exactly 32 chars)
        let valid = "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-hello-1.0";
        assert!(StorePath::<String>::from_absolute_path(valid.as_bytes()).is_ok());

        // Invalid paths
        let invalid_paths: Vec<&str> = vec![
            "/invalid/path",
            "/nix/store/",
            "not-absolute",
            "/nix/store/tooshort-hello",  // hash too short
        ];

        for path in invalid_paths {
            assert!(StorePath::<String>::from_absolute_path(path.as_bytes()).is_err());
        }

        // Test overly long path
        let toolong = "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-".to_string() + &"x".repeat(300);
        assert!(StorePath::<String>::from_absolute_path(toolong.as_bytes()).is_err());
    }

    #[test]
    fn xz_decompression_roundtrip() {
        let original = b"test data for xz compression";

        // Compress with lzma-rs
        let mut compressed = Vec::new();
        lzma_rs::xz_compress(&mut &original[..], &mut compressed).unwrap();

        // Decompress
        let mut decompressed = Vec::new();
        lzma_rs::xz_decompress(&mut &compressed[..], &mut decompressed).unwrap();

        assert_eq!(decompressed, original);
    }

    #[test]
    fn bzip2_decompression() {
        // bzip2-rs is decoder-only, so we test with pre-compressed data
        // "hello" compressed with bzip2 (generated with: echo -n "hello" | bzip2)
        let compressed = vec![
            0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26,
            0x53, 0x59, 0x19, 0x31, 0x65, 0x3d, 0x00, 0x00,
            0x00, 0x81, 0x00, 0x02, 0x44, 0xa0, 0x00, 0x21,
            0x9a, 0x68, 0x33, 0x4d, 0x07, 0x33, 0x8b, 0xb9,
            0x22, 0x9c, 0x28, 0x48, 0x0c, 0x98, 0xb2, 0x9e,
            0x80,
        ];

        let mut decompressor = bzip2_rs::DecoderReader::new(&compressed[..]);
        let mut decompressed = Vec::new();
        decompressor.read_to_end(&mut decompressed).unwrap();

        assert_eq!(decompressed, b"hello");
    }
}
