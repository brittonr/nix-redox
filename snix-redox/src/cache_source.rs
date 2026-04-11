//! Unified cache source abstraction.
//!
//! `CacheSource` abstracts over local filesystem and remote HTTP binary caches.
//! All package operations (install, search, show) work identically regardless
//! of cache source.
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
const REMOTE_TIMEOUT_SECS: u64 = 30;
const PARSE_ERROR_PREVIEW_BYTES: usize = 200;

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
    ///   3. Default `/nix/cache` → Local
    pub fn from_args(cache_url: Option<&str>, cache_path: Option<&str>) -> Self {
        if let Some(url) = cache_url {
            return CacheSource::Remote(url.trim_end_matches('/').to_string());
        }

        if let Some(path) = cache_path {
            return CacheSource::Local(PathBuf::from(path));
        }

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
            CacheSource::Local(path) => local_cache::read_index(&path.to_string_lossy()),
            CacheSource::Remote(url) => self.fetch_package_index(url),
        }
    }

    fn fetch_package_index(&self, url: &str) -> Result<PackageIndex, Box<dyn std::error::Error>> {
        let index_url = format!("{url}/packages.json");
        let body = http_get_text(&index_url)?;
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "failed to parse packages.json from {index_url}: {e}; body starts with {:?}",
                preview_bytes(body.as_bytes(), PARSE_ERROR_PREVIEW_BYTES)
            )
            .into()
        })
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
            CacheSource::Remote(url) => self.fetch_remote_narinfo(url, &hash)?,
        };

        let body_static: &'static str = Box::leak(body.into_boxed_str());
        Ok(NarInfo::parse(body_static)?)
    }

    fn fetch_remote_narinfo(
        &self,
        url: &str,
        hash: &str,
    ) -> Result<String, Box<dyn std::error::Error>> {
        let narinfo_url = format!("{url}/{hash}.narinfo");
        http_get_text(&narinfo_url)
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
            CacheSource::Remote(url) => self.fetch_remote_nar(url, &narinfo.url),
        }
    }

    fn fetch_remote_nar(
        &self,
        url: &str,
        nar_relative_url: &str,
    ) -> Result<Box<dyn Read + Send>, Box<dyn std::error::Error>> {
        let nar_url = format!("{url}/{nar_relative_url}");
        eprintln!("downloading {nar_relative_url}...");
        let response = http_get_lazy(&nar_url)?;
        Ok(Box::new(MinreqLazyReader { response }))
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
    pub fn search(&self, pattern: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
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
    pub fn show_package(&self, name: &str) -> Result<(), Box<dyn std::error::Error>> {
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

struct MinreqLazyReader {
    response: minreq::ResponseLazy,
}

impl Read for MinreqLazyReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let mut written = 0;
        for slot in buf.iter_mut() {
            match self.response.next() {
                Some(Ok((byte, _remaining))) => {
                    *slot = byte;
                    written += 1;
                }
                Some(Err(err)) => {
                    if written > 0 {
                        return Ok(written);
                    }
                    return Err(io::Error::new(io::ErrorKind::Other, err.to_string()));
                }
                None => break,
            }
        }

        Ok(written)
    }
}

fn http_get_text(url: &str) -> Result<String, Box<dyn std::error::Error>> {
    let response = http_get(url)?;
    response
        .as_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("failed to read response from {url}: {e}").into())
}

fn http_get(url: &str) -> Result<minreq::Response, Box<dyn std::error::Error>> {
    let response = minreq::get(url)
        .with_timeout(REMOTE_TIMEOUT_SECS)
        .send()
        .map_err(|e| format!("failed to fetch {url}: {e}"))?;
    ensure_http_success(url, response.status_code, &response.reason_phrase)?;
    Ok(response)
}

fn http_get_lazy(url: &str) -> Result<minreq::ResponseLazy, Box<dyn std::error::Error>> {
    let response = minreq::get(url)
        .with_timeout(REMOTE_TIMEOUT_SECS)
        .send_lazy()
        .map_err(|e| format!("failed to fetch {url}: {e}"))?;
    ensure_http_success(url, response.status_code, &response.reason_phrase)?;
    Ok(response)
}

fn ensure_http_success(
    url: &str,
    status_code: i32,
    reason_phrase: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if (200..300).contains(&status_code) {
        return Ok(());
    }

    Err(format!("failed to fetch {url}: HTTP {status_code} {reason_phrase}").into())
}

fn preview_bytes(bytes: &[u8], max_len: usize) -> String {
    let end = bytes.len().min(max_len);
    let mut preview = String::from_utf8_lossy(&bytes[..end]).into_owned();
    if bytes.len() > max_len {
        preview.push_str("...");
    }
    preview
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
    use std::io::{Read as _, Write};
    use std::net::TcpListener;
    use std::thread;

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

    #[test]
    fn remote_read_index_fetches_packages_json() {
        let server = serve_once(
            "200 OK",
            r#"{"version":1,"packages":{"ripgrep":{"pname":"ripgrep","version":"14.0","storePath":"/nix/store/abc-ripgrep-14.0"}}}"#,
            "application/json",
        );
        let src = CacheSource::Remote(server);

        let index = src.read_index().unwrap();
        let entry = index.packages.get("ripgrep").unwrap();
        assert_eq!(entry.pname, "ripgrep");
        assert_eq!(entry.version, "14.0");
        assert_eq!(entry.store_path, "/nix/store/abc-ripgrep-14.0");
    }

    #[test]
    fn remote_read_index_parse_error_includes_body_preview() {
        let server = serve_once("200 OK", "not-json-at-all", "application/json");
        let src = CacheSource::Remote(server);

        let err = src.read_index().unwrap_err().to_string();
        assert!(err.contains("failed to parse packages.json"));
        assert!(err.contains("not-json-at-all"));
    }

    #[test]
    fn remote_fetch_narinfo_http_error_includes_url_and_status() {
        let server = serve_once("404 Not Found", "missing", "text/plain");
        let src = CacheSource::Remote(server.clone());
        let sp = store_path("/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-hello");

        let err = src.fetch_narinfo(&sp).unwrap_err().to_string();
        assert!(err.contains(&format!("{server}/")));
        assert!(err.contains("HTTP 404 Not Found"));
    }

    #[test]
    fn remote_open_nar_reads_response_body() {
        let server = serve_once("200 OK", "nar-bytes", "application/octet-stream");
        let src = CacheSource::Remote(server);
        let narinfo = parse_narinfo(
            "StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello\nURL: hello.nar\nCompression: none\nNarHash: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nNarSize: 0\n",
        );

        let mut reader = src.open_nar(&narinfo).unwrap();
        let mut body = String::new();
        reader.read_to_string(&mut body).unwrap();
        assert_eq!(body, "nar-bytes");
    }

    fn serve_once(status_line: &str, body: &str, content_type: &str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let status_line = status_line.to_string();
        let body = body.as_bytes().to_vec();
        let content_type = content_type.to_string();

        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request_buf = [0_u8; 4096];
            let _ = stream.read(&mut request_buf);
            write!(
                stream,
                "HTTP/1.1 {status_line}\r\nContent-Length: {}\r\nContent-Type: {content_type}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            stream.write_all(&body).unwrap();
            stream.flush().unwrap();
        });

        format!("http://{addr}")
    }

    fn parse_narinfo(text: &str) -> NarInfo<'static> {
        let leaked: &'static str = Box::leak(text.to_string().into_boxed_str());
        NarInfo::parse(leaked).unwrap()
    }

    fn store_path(path: &str) -> StorePath<String> {
        StorePath::from_absolute_path(path.as_bytes()).unwrap()
    }
}
