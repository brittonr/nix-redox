//! Local filesystem binary cache reader.
//!
//! Reads Nix binary cache format from a local directory (e.g. /nix/cache/).
//! Same format as HTTP binary caches but accessed via filesystem I/O.
//!
//! Layout:
//!   /nix/cache/nix-cache-info    — cache metadata
//!   /nix/cache/packages.json     — name → store path index
//!   /nix/cache/{hash}.narinfo    — per-path metadata
//!   /nix/cache/nar/*.nar.zst     — compressed NAR files

use std::collections::BTreeMap;
use std::io::{self, BufReader, Read};
use std::path::{Path, PathBuf};

use nix_compat::narinfo::NarInfo;
use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;
use sha2::{Digest, Sha256};

use crate::nar;
use crate::pathinfo::PathInfoDb;
use crate::store;

/// Default local cache path on Redox.
pub const DEFAULT_CACHE_PATH: &str = "/nix/cache";

/// Package index entry from packages.json.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageEntry {
    pub store_path: String,
    pub pname: String,
    pub version: String,
    pub nar_hash: Option<String>,
    pub nar_size: Option<u64>,
    pub file_size: Option<u64>,
}

/// Package index (packages.json).
#[derive(Debug, serde::Deserialize)]
pub struct PackageIndex {
    pub version: u32,
    pub packages: BTreeMap<String, PackageEntry>,
}

/// Read the package index from a local cache.
pub fn read_index(cache_path: &str) -> Result<PackageIndex, Box<dyn std::error::Error>> {
    let index_path = PathBuf::from(cache_path).join("packages.json");
    let content = std::fs::read_to_string(&index_path)
        .map_err(|e| format!("cannot read {}: {e}", index_path.display()))?;
    let index: PackageIndex = serde_json::from_str(&content)?;
    Ok(index)
}

/// Search for packages matching a pattern.
pub fn search(cache_path: &str, pattern: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let index = read_index(cache_path)?;

    let matches: Vec<_> = index
        .packages
        .iter()
        .filter(|(name, entry)| match pattern {
            Some(pat) => {
                let pat_lower = pat.to_lowercase();
                name.to_lowercase().contains(&pat_lower)
                    || entry.pname.to_lowercase().contains(&pat_lower)
            }
            None => true,
        })
        .collect();

    if matches.is_empty() {
        if let Some(pat) = pattern {
            eprintln!("No packages matching '{pat}'");
        } else {
            eprintln!("No packages in cache");
        }
        return Ok(());
    }

    println!("{} packages available:", matches.len());
    println!();
    for (name, entry) in &matches {
        let size_str = match entry.file_size {
            Some(s) => format_size(s),
            None => "?".to_string(),
        };
        let installed = Path::new(&entry.store_path).exists();
        let status = if installed { " [installed]" } else { "" };
        println!(
            "  {:<16} {:<12} {:>8}{}",
            name, entry.version, size_str, status
        );
    }
    println!();

    Ok(())
}

/// Fetch a store path from a local binary cache.
///
/// Reads narinfo, decompresses NAR, extracts to /nix/store/, verifies hash.
pub fn fetch_local(
    store_path: &str,
    cache_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let sp = StorePath::<String>::from_absolute_path(store_path.as_bytes())?;
    let dest = sp.to_absolute_path();

    // Already present?
    if Path::new(&dest).exists() {
        eprintln!("already exists: {dest}");
        return Ok(());
    }

    store::ensure_store_dir()?;

    // Read narinfo
    let hash = nixbase32::encode(sp.digest());
    let narinfo_path = PathBuf::from(cache_path).join(format!("{hash}.narinfo"));
    let narinfo_text = std::fs::read_to_string(&narinfo_path)
        .map_err(|e| format!("narinfo not found: {}: {e}", narinfo_path.display()))?;

    let narinfo_static: &'static str = Box::leak(narinfo_text.into_boxed_str());
    let narinfo = NarInfo::parse(narinfo_static)?;

    // Read compressed NAR
    let nar_path = PathBuf::from(cache_path).join(&*narinfo.url);
    eprintln!("extracting {}...", nar_path.display());

    let file = std::fs::File::open(&nar_path)
        .map_err(|e| format!("NAR file not found: {}: {e}", nar_path.display()))?;
    let reader = BufReader::new(file);

    // Decompress (all decompressors produce Send types)
    let decompressed: Box<dyn Read + Send> = match narinfo.compression {
        None | Some("none") => Box::new(reader),
        Some("zstd") | Some("zst") => Box::new(
            ruzstd::decoding::StreamingDecoder::new(reader)
                .map_err(|e| format!("zstd decompression error: {e}"))?,
        ),
        Some("xz") => {
            let mut input = BufReader::new(reader);
            let mut output = Vec::new();
            lzma_rs::xz_decompress(&mut input, &mut output)
                .map_err(|e| format!("xz decompression error: {e}"))?;
            Box::new(io::Cursor::new(output))
        }
        Some("bzip2") | Some("bz2") => Box::new(bzip2_rs::DecoderReader::new(reader)),
        Some(other) => return Err(format!("unsupported compression: {other}").into()),
    };

    // Hash while extracting
    let mut hashing = HashingReader::new(decompressed);
    let mut buf_reader = BufReader::new(&mut hashing);

    eprintln!("extracting to {dest}...");
    nar::extract(&mut buf_reader, &dest)?;

    // Verify NAR hash
    let actual_hash = hashing.finalize();
    if actual_hash != narinfo.nar_hash {
        let _ = std::fs::remove_dir_all(&dest);
        return Err(format!(
            "NAR hash mismatch!\n  expected: {}\n  got:      {}",
            data_encoding::HEXLOWER.encode(&narinfo.nar_hash),
            data_encoding::HEXLOWER.encode(&actual_hash),
        )
        .into());
    }

    // Register in PathInfo database
    let db = PathInfoDb::open()?;
    let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
    let references: Vec<String> = narinfo
        .references
        .iter()
        .map(|r| r.to_absolute_path())
        .collect();
    let signatures: Vec<String> = narinfo.signatures.iter().map(|s| s.to_string()).collect();

    store::register_path(&db, &dest, &nar_hash_hex, narinfo.nar_size, references, signatures)?;

    eprintln!("✓ verified and installed: {dest}");
    Ok(())
}

// ─── Helpers ───────────────────────────────────────────────────────────────

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

fn format_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.0} KB", bytes as f64 / KB as f64)
    } else {
        format!("{bytes} B")
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_package_index() {
        let json = r#"{
            "version": 1,
            "packages": {
                "ripgrep": {
                    "storePath": "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-ripgrep-14.1.0",
                    "pname": "ripgrep",
                    "version": "14.1.0",
                    "narHash": "sha256:abc123",
                    "narSize": 5000000,
                    "fileSize": 2000000
                }
            }
        }"#;

        let index: PackageIndex = serde_json::from_str(json).unwrap();
        assert_eq!(index.version, 1);
        assert_eq!(index.packages.len(), 1);

        let rg = &index.packages["ripgrep"];
        assert_eq!(rg.pname, "ripgrep");
        assert_eq!(rg.version, "14.1.0");
        assert_eq!(rg.file_size, Some(2000000));
    }

    #[test]
    fn format_sizes() {
        assert_eq!(format_size(0), "0 B");
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(1024), "1 KB");
        assert_eq!(format_size(1536), "2 KB");
        assert_eq!(format_size(1048576), "1.0 MB");
        assert_eq!(format_size(5242880), "5.0 MB");
    }

    #[test]
    fn package_index_missing_optional_fields() {
        let json = r#"{
            "version": 1,
            "packages": {
                "test": {
                    "storePath": "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-test-1.0",
                    "pname": "test",
                    "version": "1.0"
                }
            }
        }"#;

        let index: PackageIndex = serde_json::from_str(json).unwrap();
        let pkg = &index.packages["test"];
        assert_eq!(pkg.nar_hash, None);
        assert_eq!(pkg.nar_size, None);
        assert_eq!(pkg.file_size, None);
    }
}
