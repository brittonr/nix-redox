//! Unified cache source abstraction.
//!
//! `CacheSource` abstracts over local filesystem and remote HTTP binary caches.
//! All package operations (install, search, show, fetch) work identically
//! regardless of cache source.
//!
//! ```text
//! CacheSource::Local("/nix/cache")         — reads files from disk
//! CacheSource::Remote("http://10.0.2.2")   — fetches files via HTTP GET
//! ```

use std::io::{self, BufReader, Read};
use std::path::{Path, PathBuf};

use nix_compat::narinfo::NarInfo;
use nix_compat::nixbase32;
use nix_compat::store_path::StorePath;

use crate::local_cache::{self, PackageIndex};

/// Default local cache path on Redox.
pub const DEFAULT_CACHE_PATH: &str = "/nix/cache";

/// A binary cache source — either local filesystem or remote HTTP.
#[derive(Debug, Clone)]
pub enum CacheSource {
    /// Local filesystem cache at a directory path.
    Local(PathBuf),
    /// Remote HTTP binary cache at a URL.
    Remote(String),
}

impl CacheSource {
    /// Determine cache source from CLI arguments.
    ///
    /// Priority:
    ///   1. `--cache-url` (HTTP/HTTPS URL) → Remote
    ///   2. `--cache-path` (filesystem path) → Local
    ///   3. `SNIX_CACHE_PATH` env var → Local
    ///   4. Default `/nix/cache` → Local
    pub fn from_args(cache_url: Option<&str>, cache_path: Option<&str>) -> Self {
        if let Some(url) = cache_url {
            return CacheSource::Remote(url.trim_end_matches('/').to_string());
        }

        if let Some(path) = cache_path {
            return CacheSource::Local(PathBuf::from(path));
        }

        // Fall through to default
        CacheSource::Local(PathBuf::from(DEFAULT_CACHE_PATH))
    }

    /// Determine cache source from a single string that could be a URL or path.
    ///
    /// If the string starts with `http://` or `https://`, it's a Remote.
    /// Otherwise, it's a Local path.
    pub fn detect(source: &str) -> Self {
        if source.starts_with("http://") || source.starts_with("https://") {
            CacheSource::Remote(source.trim_end_matches('/').to_string())
        } else {
            CacheSource::Local(PathBuf::from(source))
        }
    }

    /// Is this a remote (HTTP) cache?
    pub fn is_remote(&self) -> bool {
        matches!(self, CacheSource::Remote(_))
    }

    /// Is this a local (filesystem) cache?
    pub fn is_local(&self) -> bool {
        matches!(self, CacheSource::Local(_))
    }

    /// Human-readable description for error messages.
    pub fn display_name(&self) -> String {
        match self {
            CacheSource::Local(p) => format!("local cache at {}", p.display()),
            CacheSource::Remote(u) => format!("remote cache at {u}"),
        }
    }

    // ── Package Index ──────────────────────────────────────────────────

    /// Read the package index (packages.json) from the cache.
    pub fn read_index(&self) -> Result<PackageIndex, Box<dyn std::error::Error>> {
        match self {
            CacheSource::Local(path) => {
                local_cache::read_index(&path.to_string_lossy())
            }
            CacheSource::Remote(url) => {
                let index_url = format!("{url}/packages.json");
                let resp = ureq::get(&index_url)
                    .call()
                    .map_err(|e| format!("failed to fetch {index_url}: {e}"))?;
                let body = resp
                    .into_body()
                    .read_to_string()
                    .map_err(|e| format!("failed to read response from {index_url}: {e}"))?;
                let index: PackageIndex = serde_json::from_str(&body)
                    .map_err(|e| format!("failed to parse packages.json from {index_url}: {e}"))?;
                Ok(index)
            }
        }
    }

    // ── NarInfo ────────────────────────────────────────────────────────

    /// Fetch narinfo for a store path.
    ///
    /// Returns parsed NarInfo with 'static lifetime (the backing string is leaked).
    pub fn fetch_narinfo(
        &self,
        sp: &StorePath<String>,
    ) -> Result<NarInfo<'static>, Box<dyn std::error::Error>> {
        let hash = nixbase32::encode(sp.digest());

        let body = match self {
            CacheSource::Local(path) => {
                let narinfo_path = path.join(format!("{hash}.narinfo"));
                std::fs::read_to_string(&narinfo_path)
                    .map_err(|e| format!("narinfo not found: {}: {e}", narinfo_path.display()))?
            }
            CacheSource::Remote(url) => {
                let narinfo_url = format!("{url}/{hash}.narinfo");
                let resp = ureq::get(&narinfo_url)
                    .call()
                    .map_err(|e| format!("failed to fetch {narinfo_url}: {e}"))?;
                resp.into_body()
                    .read_to_string()
                    .map_err(|e| format!("failed to read narinfo from {narinfo_url}: {e}"))?
            }
        };

        // NarInfo::parse borrows from the input — leak to get 'static lifetime.
        // Fine for a CLI tool.
        let body_static: &'static str = Box::leak(body.into_boxed_str());
        let narinfo = NarInfo::parse(body_static)?;
        Ok(narinfo)
    }

    // ── NAR Download ───────────────────────────────────────────────────

    /// Open a NAR file for reading (possibly compressed).
    ///
    /// Returns a reader over the raw (compressed) NAR content.
    /// Caller is responsible for decompression based on narinfo.compression.
    pub fn open_nar(
        &self,
        narinfo: &NarInfo<'_>,
    ) -> Result<Box<dyn Read + Send>, Box<dyn std::error::Error>> {
        match self {
            CacheSource::Local(path) => {
                let nar_path = path.join(&*narinfo.url);
                let file = std::fs::File::open(&nar_path)
                    .map_err(|e| format!("NAR file not found: {}: {e}", nar_path.display()))?;
                Ok(Box::new(BufReader::new(file)))
            }
            CacheSource::Remote(url) => {
                let nar_url = format!("{url}/{}", narinfo.url);
                eprintln!("downloading {}...", narinfo.url);
                let resp = ureq::get(&nar_url)
                    .call()
                    .map_err(|e| format!("failed to download {nar_url}: {e}"))?;
                Ok(Box::new(resp.into_body().into_reader()))
            }
        }
    }

    // ── Decompression Helper ───────────────────────────────────────────

    /// Open and decompress a NAR from this cache source.
    ///
    /// Handles zstd, xz, bzip2, and uncompressed NARs.
    pub fn open_nar_decompressed(
        &self,
        narinfo: &NarInfo<'_>,
    ) -> Result<Box<dyn Read + Send>, Box<dyn std::error::Error>> {
        let reader = self.open_nar(narinfo)?;

        match narinfo.compression {
            None | Some("none") => Ok(reader),
            Some("zstd") | Some("zst") => Ok(Box::new(
                ruzstd::decoding::StreamingDecoder::new(reader)
                    .map_err(|e| format!("zstd decompression error: {e}"))?,
            )),
            Some("xz") => {
                let mut input = BufReader::new(reader);
                let mut output = Vec::new();
                lzma_rs::xz_decompress(&mut input, &mut output)
                    .map_err(|e| format!("xz decompression error: {e}"))?;
                Ok(Box::new(io::Cursor::new(output)))
            }
            Some("bzip2") | Some("bz2") => Ok(Box::new(bzip2_rs::DecoderReader::new(reader))),
            Some(other) => Err(format!("unsupported compression: {other}").into()),
        }
    }

    // ── Search ─────────────────────────────────────────────────────────

    /// Search for packages matching an optional pattern.
    ///
    /// Fetches the package index and filters by substring match on name/pname.
    pub fn search(
        &self,
        pattern: Option<&str>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let index = self.read_index()?;

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
                eprintln!("No packages in cache at {}", self.display_name());
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

    // ── Show ───────────────────────────────────────────────────────────

    /// Show detailed info about a cached package.
    pub fn show_package(
        &self,
        name: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let index = self.read_index()?;
        let entry = index
            .packages
            .get(name)
            .ok_or_else(|| format!("package '{name}' not found in {}", self.display_name()))?;

        let in_store = Path::new(&entry.store_path).exists();

        println!("Package: {name}");
        println!("  Name:       {}", entry.pname);
        println!("  Version:    {}", entry.version);
        println!("  Store path: {}", entry.store_path);
        println!("  Source:     {}", self.display_name());
        if let Some(nar_hash) = &entry.nar_hash {
            println!("  NAR hash:   {nar_hash}");
        }
        if let Some(nar_size) = entry.nar_size {
            println!("  NAR size:   {}", format_size(nar_size));
        }
        if let Some(file_size) = entry.file_size {
            println!("  Cache size: {}", format_size(file_size));
        }
        println!("  In store:   {}", if in_store { "yes" } else { "no" });

        // Show binaries if present in store
        if in_store {
            let bin_dir = PathBuf::from(&entry.store_path).join("bin");
            if bin_dir.is_dir() {
                if let Ok(mut bins) = list_binaries(&bin_dir) {
                    bins.sort();
                    if !bins.is_empty() {
                        println!("  Binaries:");
                        for bin in &bins {
                            println!("    {bin}");
                        }
                    }
                }
            }
        }

        Ok(())
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn list_binaries(bin_dir: &Path) -> Result<Vec<String>, std::io::Error> {
    let mut bins = Vec::new();
    if bin_dir.is_dir() {
        for entry in std::fs::read_dir(bin_dir)? {
            let entry = entry?;
            bins.push(entry.file_name().to_string_lossy().to_string());
        }
    }
    Ok(bins)
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

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_args_cache_url_takes_priority() {
        let src = CacheSource::from_args(Some("http://example.com/cache"), Some("/local/cache"));
        assert!(src.is_remote());
        match src {
            CacheSource::Remote(u) => assert_eq!(u, "http://example.com/cache"),
            _ => panic!("expected Remote"),
        }
    }

    #[test]
    fn from_args_cache_path_when_no_url() {
        let src = CacheSource::from_args(None, Some("/my/cache"));
        assert!(src.is_local());
        match src {
            CacheSource::Local(p) => assert_eq!(p, PathBuf::from("/my/cache")),
            _ => panic!("expected Local"),
        }
    }

    #[test]
    fn from_args_defaults_to_nix_cache() {
        let src = CacheSource::from_args(None, None);
        assert!(src.is_local());
        match src {
            CacheSource::Local(p) => assert_eq!(p, PathBuf::from("/nix/cache")),
            _ => panic!("expected Local"),
        }
    }

    #[test]
    fn detect_http_url() {
        let src = CacheSource::detect("http://10.0.2.2:8080");
        assert!(src.is_remote());
    }

    #[test]
    fn detect_https_url() {
        let src = CacheSource::detect("https://cache.example.com/nix");
        assert!(src.is_remote());
    }

    #[test]
    fn detect_filesystem_path() {
        let src = CacheSource::detect("/nix/cache");
        assert!(src.is_local());
    }

    #[test]
    fn detect_relative_path() {
        let src = CacheSource::detect("./cache");
        assert!(src.is_local());
    }

    #[test]
    fn trailing_slash_stripped_from_url() {
        let src = CacheSource::from_args(Some("http://host:8080/"), None);
        match src {
            CacheSource::Remote(u) => assert_eq!(u, "http://host:8080"),
            _ => panic!("expected Remote"),
        }
    }

    #[test]
    fn display_name_local() {
        let src = CacheSource::Local(PathBuf::from("/nix/cache"));
        assert!(src.display_name().contains("/nix/cache"));
        assert!(src.display_name().contains("local"));
    }

    #[test]
    fn display_name_remote() {
        let src = CacheSource::Remote("http://10.0.2.2:8080".to_string());
        assert!(src.display_name().contains("http://10.0.2.2:8080"));
        assert!(src.display_name().contains("remote"));
    }

    #[test]
    fn clone_preserves_variant() {
        let local = CacheSource::Local(PathBuf::from("/cache"));
        let cloned = local.clone();
        assert!(cloned.is_local());

        let remote = CacheSource::Remote("http://x".to_string());
        let cloned = remote.clone();
        assert!(cloned.is_remote());
    }
}
