//! Fetcher builtins (`builtins.fetchurl`, `builtins.fetchTarball`)
//!
//! These builtins create fixed-output derivations (FODs) with
//! `builder = "builtin:fetchurl"` or `builder = "builtin:fetchTarball"`.
//! The actual downloading happens at build time in [`local_build::build_derivation`],
//! not during evaluation.
//!
//! This matches upstream Nix behavior: the store path is deterministic
//! (computed from the content hash), and the build can be skipped if the
//! output already exists in the store.
//!
//! ## Usage
//!
//! ```nix
//! # Simple form — URL string
//! builtins.fetchurl "https://example.com/file.txt"
//!
//! # Attrset form with hash
//! builtins.fetchurl {
//!   url = "https://example.com/file.txt";
//!   sha256 = "sha256-...";  # SRI, hex, or base32
//!   name = "myfile.txt";    # optional, defaults to URL basename
//! }
//! ```

use std::rc::Rc;

use bstr::BString;
use nix_compat::derivation::{Derivation, Output};
use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
use nix_compat::store_path::StorePath;
use snix_eval::builtin_macros::builtins;
use snix_eval::generators::{self, GenCo};
use snix_eval::{ErrorKind, NixAttrs, NixContext, NixContextElement, NixString, Value};

use crate::derivation_builtins::SnixRedoxState;

// ── Helpers ────────────────────────────────────────────────────────────────

/// Extract the basename from a URL for use as the default derivation name.
///
/// Takes the last path component, stripping query strings and fragments.
/// Falls back to "source" if the URL has no usable basename.
fn url_basename(url: &str) -> String {
    // Strip fragment (#...) and query (?...)
    let path = url.split('#').next().unwrap_or(url);
    let path = path.split('?').next().unwrap_or(path);

    // Get the last path component
    let basename = path
        .rsplit('/')
        .next()
        .unwrap_or("source")
        .to_string();

    if basename.is_empty() {
        "source".to_string()
    } else {
        // Sanitize for store path name
        sanitize_name(&basename)
    }
}

/// Sanitize a string for use as a Nix store path name.
/// Nix store names allow: [a-zA-Z0-9+\-._?=] and must not start with '.'.
fn sanitize_name(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "-_+=.?".contains(c) {
                c
            } else {
                '-'
            }
        })
        .collect();

    if sanitized.starts_with('.') {
        format!("_{}", &sanitized[1..])
    } else if sanitized.is_empty() {
        "source".to_string()
    } else {
        sanitized
    }
}

/// Parse fetch arguments from either a URL string or an attrset.
///
/// Returns `(url, name, sha256, unpack)`.
async fn parse_fetch_args(
    co: &GenCo,
    args: Value,
    default_unpack: bool,
) -> Result<(String, String, Option<String>, bool), ErrorKind> {
    match args {
        // Simple string form: builtins.fetchurl "https://..."
        Value::String(s) => {
            let url = s.as_str()?.to_owned();
            let name = url_basename(&url);
            Ok((url, name, None, default_unpack))
        }

        // Attrset form: builtins.fetchurl { url = "..."; sha256 = "..."; }
        Value::Attrs(attrs) => {
            let url = match attrs.select("url") {
                Some(v) => {
                    let forced = generators::request_force(co, v.clone()).await;
                    if forced.is_catchable() {
                        return Err(ErrorKind::Abort(
                            "fetchurl: error evaluating 'url'".to_string(),
                        ));
                    }
                    forced.to_str()?.as_str()?.to_owned()
                }
                None => {
                    return Err(ErrorKind::Abort(
                        "fetchurl: attribute 'url' is required".to_string(),
                    ));
                }
            };

            let name = match attrs.select("name") {
                Some(v) => {
                    let forced = generators::request_force(co, v.clone()).await;
                    forced.to_str()?.as_str()?.to_owned()
                }
                None => url_basename(&url),
            };

            let sha256 = match attrs.select("sha256") {
                Some(v) => {
                    let forced = generators::request_force(co, v.clone()).await;
                    let s = forced.to_str()?.as_str()?.to_owned();
                    if s.is_empty() {
                        None
                    } else {
                        Some(s)
                    }
                }
                None => None,
            };

            let unpack = match attrs.select("unpack") {
                Some(v) => {
                    let forced = generators::request_force(co, v.clone()).await;
                    forced.as_bool()?
                }
                None => default_unpack,
            };

            Ok((url, name, sha256, unpack))
        }

        _ => Err(ErrorKind::Abort(
            "fetchurl: expected a URL string or attribute set".to_string(),
        )),
    }
}

/// Create a fixed-output derivation for a fetcher builtin.
///
/// This is the core logic shared between `fetchurl` and `fetchTarball`.
/// It constructs a FOD with `builder = "builtin:fetchurl"` and registers
/// it in KnownPaths.
fn make_fetch_derivation(
    state: &SnixRedoxState,
    url: &str,
    name: &str,
    sha256: Option<&str>,
    unpack: bool,
) -> Result<Value, ErrorKind> {
    let mut drv = Derivation::default();
    drv.builder = "builtin:fetchurl".to_string();
    drv.system = "builtin".to_string();

    // Set the URL in the environment (the builder reads it from here)
    drv.environment
        .insert("url".to_string(), BString::from(url));
    drv.environment
        .insert("name".to_string(), BString::from(name));

    // Set output hash mode
    let hash_mode = if unpack { "recursive" } else { "flat" };

    // Configure outputs
    if let Some(hash_str) = sha256 {
        // Parse the hash — supports SRI (sha256-...), hex, and nixbase32
        let nixhash = NixHash::from_str(hash_str, Some(HashAlgo::Sha256))
            .map_err(|e| ErrorKind::Abort(format!("fetchurl: invalid hash: {e}")))?;

        let ca_hash = if unpack {
            CAHash::Nar(nixhash)
        } else {
            CAHash::Flat(nixhash)
        };

        drv.outputs.insert(
            "out".to_string(),
            Output {
                path: None,
                ca_hash: Some(ca_hash),
            },
        );

        // Also put these in the environment for the builder
        drv.environment
            .insert("outputHash".to_string(), BString::from(hash_str));
        drv.environment
            .insert("outputHashAlgo".to_string(), BString::from("sha256"));
        drv.environment
            .insert("outputHashMode".to_string(), BString::from(hash_mode));
    } else {
        // No hash specified — impure fetch (the output path will be
        // computed after download based on actual content hash).
        // For now, require a hash — impure fetches are dangerous.
        return Err(ErrorKind::Abort(
            "fetchurl: 'sha256' attribute is required (impure fetches not supported)".to_string(),
        ));
    }

    // Set unpack flag in environment
    if unpack {
        drv.environment
            .insert("unpack".to_string(), BString::from("1"));
    }

    // Output placeholder in environment (needed for path calculation)
    drv.environment
        .insert("out".to_string(), String::new().into());

    // Validate
    drv.validate(false)
        .map_err(|e| ErrorKind::Abort(format!("fetchurl: invalid derivation: {e}")))?;

    // Calculate output paths
    let mut known_paths = state.known_paths.borrow_mut();

    let hash_derivation_modulo = drv.hash_derivation_modulo(|drv_path| {
        *known_paths
            .get_hash_derivation_modulo(&drv_path.to_owned())
            .unwrap_or_else(|| panic!("{drv_path} not found"))
    });

    drv.calculate_output_paths(name, &hash_derivation_modulo)
        .map_err(|e| ErrorKind::Abort(format!("fetchurl: path calculation failed: {e}")))?;

    let drv_path = drv
        .calculate_derivation_path(name)
        .map_err(|e| ErrorKind::Abort(format!("fetchurl: drv path calculation failed: {e}")))?;

    // Build the return value — the output store path with derivation context
    let out_path = drv
        .outputs
        .get("out")
        .and_then(|o| o.path.as_ref())
        .expect("output path must be set after calculate_output_paths")
        .to_absolute_path();

    let result = Value::from(NixString::new_context_from(
        NixContextElement::Single {
            name: "out".to_string(),
            derivation: drv_path.to_absolute_path(),
        }
        .into(),
        out_path,
    ));

    // Register in KnownPaths
    known_paths.add_derivation(drv_path, drv);

    Ok(result)
}

// ── Fetcher builtins module ────────────────────────────────────────────────

#[builtins(state = "Rc<SnixRedoxState>")]
pub(crate) mod fetcher_builtins {
    use super::*;
    use genawaiter::rc::Gen;

    /// `builtins.fetchurl` — fetch a file from a URL.
    ///
    /// Creates a fixed-output derivation with `builder = "builtin:fetchurl"`.
    /// The actual download happens at build time (when the store path is needed).
    ///
    /// Accepts either a URL string or an attrset:
    /// ```nix
    /// builtins.fetchurl "https://example.com/file.txt"
    /// builtins.fetchurl { url = "..."; sha256 = "..."; name = "..."; }
    /// ```
    #[builtin("fetchurl")]
    async fn builtin_fetchurl(
        state: Rc<SnixRedoxState>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        if args.is_catchable() {
            return Ok(args);
        }

        let (url, name, sha256, unpack) = parse_fetch_args(&co, args, false).await?;

        make_fetch_derivation(&state, &url, &name, sha256.as_deref(), unpack)
    }

    /// `builtins.fetchTarball` — fetch and unpack a tarball from a URL.
    ///
    /// Like `fetchurl` but with `unpack = true` by default (recursive hash mode).
    ///
    /// ```nix
    /// builtins.fetchTarball "https://example.com/src.tar.gz"
    /// builtins.fetchTarball { url = "..."; sha256 = "..."; }
    /// ```
    #[builtin("fetchTarball")]
    async fn builtin_fetch_tarball(
        state: Rc<SnixRedoxState>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        if args.is_catchable() {
            return Ok(args);
        }

        let (url, name, sha256, unpack) = parse_fetch_args(&co, args, true).await?;

        make_fetch_derivation(&state, &url, &name, sha256.as_deref(), unpack)
    }
}

// ── Build-time fetcher execution ───────────────────────────────────────────

/// Download a URL and write the content to a file.
///
/// Called from [`local_build::build_derivation`] when the builder is
/// `"builtin:fetchurl"`. Reads `url` from the derivation environment.
///
/// For flat mode (default): writes the raw downloaded bytes to `$out`.
/// For recursive/unpack mode: downloads a tarball, extracts to `$out/`.
pub fn fetch_to_store(
    drv: &nix_compat::derivation::Derivation,
) -> Result<(), Box<dyn std::error::Error>> {
    let url = drv
        .environment
        .get("url")
        .ok_or("builtin:fetchurl: 'url' not set in environment")?
        .to_string();

    let out = drv
        .environment
        .get("out")
        .ok_or("builtin:fetchurl: 'out' not set in environment")?
        .to_string();

    let unpack = drv
        .environment
        .get("unpack")
        .is_some_and(|v| v.to_string() == "1");

    eprintln!("fetching {url}...");

    // Ensure parent directory exists
    if let Some(parent) = std::path::Path::new(&out).parent() {
        std::fs::create_dir_all(parent)?;
    }

    if unpack {
        fetch_and_unpack(&url, &out)?;
    } else {
        fetch_flat(&url, &out)?;
    }

    eprintln!("✓ fetched to {out}");
    Ok(())
}

/// Download a URL and write the raw content to a file (flat mode).
fn fetch_flat(url: &str, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    let resp = ureq::get(url).call()?;

    let mut reader = resp.into_body().into_reader();
    let mut file = std::fs::File::create(out)?;
    std::io::copy(&mut reader, &mut file)?;

    Ok(())
}

/// Download a tarball, decompress, and extract to a directory (unpack mode).
///
/// Supports `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`, and plain `.tar`.
/// Uses the same pure-Rust decompressors as the binary cache client.
fn fetch_and_unpack(url: &str, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    let resp = ureq::get(url).call()?;
    let reader = resp.into_body().into_reader();

    // Detect compression from URL extension
    let decompressed: Box<dyn std::io::Read> = if url.ends_with(".tar.gz") || url.ends_with(".tgz")
    {
        Box::new(flate2::read::GzDecoder::new(reader))
    } else if url.ends_with(".tar.xz") || url.ends_with(".txz") {
        let mut input = std::io::BufReader::new(reader);
        let mut output = Vec::new();
        lzma_rs::xz_decompress(&mut input, &mut output)
            .map_err(|e| format!("xz decompression failed: {e}"))?;
        Box::new(std::io::Cursor::new(output))
    } else if url.ends_with(".tar.bz2") || url.ends_with(".tbz2") {
        Box::new(bzip2_rs::DecoderReader::new(reader))
    } else if url.ends_with(".tar.zst") || url.ends_with(".tar.zstd") {
        Box::new(
            ruzstd::decoding::StreamingDecoder::new(reader)
                .map_err(|e| format!("zstd decompression failed: {e}"))?,
        )
    } else if url.ends_with(".tar") {
        Box::new(reader)
    } else {
        // Default: try as gzip (many tarballs don't have .tar.gz extension)
        let mut compressed = Vec::new();
        std::io::Read::read_to_end(&mut std::io::BufReader::new(reader), &mut compressed)?;
        if compressed.len() >= 2 && compressed[0] == 0x1f && compressed[1] == 0x8b {
            // Looks like gzip
            Box::new(flate2::read::GzDecoder::new(std::io::Cursor::new(
                compressed,
            )))
        } else {
            // Assume plain tar
            Box::new(std::io::Cursor::new(compressed))
        }
    };

    // Extract tar archive
    extract_tar(decompressed, out)?;

    Ok(())
}

/// Extract a tar archive to a directory.
///
/// Minimal tar parser — handles regular files, directories, and symlinks.
/// Nix's fetchTarball strips the top-level directory component (like
/// GitHub release tarballs that have `project-version/` as the root).
fn extract_tar<R: std::io::Read>(
    reader: R,
    out: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let out_path = std::path::Path::new(out);
    std::fs::create_dir_all(out_path)?;

    let mut reader = std::io::BufReader::new(reader);
    let mut header_buf = [0u8; 512];
    let mut prefix_to_strip: Option<String> = None;

    loop {
        // Read 512-byte tar header
        match std::io::Read::read_exact(&mut reader, &mut header_buf) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e.into()),
        }

        // Check for end-of-archive (two consecutive zero blocks)
        if header_buf.iter().all(|&b| b == 0) {
            break;
        }

        // Parse header fields
        let name = parse_tar_string(&header_buf[0..100]);
        let mode = parse_tar_octal(&header_buf[100..108]);
        let size = parse_tar_octal(&header_buf[124..136]) as u64;
        let typeflag = header_buf[156];
        let linkname = parse_tar_string(&header_buf[157..257]);

        // USTAR prefix (extends the name)
        let prefix = parse_tar_string(&header_buf[345..500]);
        let full_name = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };

        // Detect and strip top-level directory prefix (like GitHub tarballs)
        if prefix_to_strip.is_none() && !full_name.is_empty() {
            // The first entry's top-level component becomes the prefix to strip
            let first_component = full_name.split('/').next().unwrap_or("");
            if !first_component.is_empty() {
                prefix_to_strip = Some(format!("{first_component}/"));
            }
        }

        // Strip the detected prefix
        let relative_name = match &prefix_to_strip {
            Some(pfx) => full_name.strip_prefix(pfx).unwrap_or(&full_name),
            None => &full_name,
        };

        // Skip empty names (the top-level directory entry itself)
        if relative_name.is_empty() || relative_name == "." {
            skip_tar_data(&mut reader, size)?;
            continue;
        }

        let dest = out_path.join(relative_name);

        match typeflag {
            b'0' | 0 => {
                // Regular file
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let mut file = std::fs::File::create(&dest)?;
                let mut remaining = size;
                let mut buf = [0u8; 8192];
                while remaining > 0 {
                    let to_read = std::cmp::min(remaining as usize, buf.len());
                    std::io::Read::read_exact(&mut reader, &mut buf[..to_read])?;
                    std::io::Write::write_all(&mut file, &buf[..to_read])?;
                    remaining -= to_read as u64;
                }
                // Skip padding to 512-byte boundary
                let padding = (512 - (size % 512)) % 512;
                skip_tar_data(&mut reader, padding)?;

                // Set permissions
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let perms = std::fs::Permissions::from_mode(mode as u32);
                    let _ = std::fs::set_permissions(&dest, perms);
                }
            }
            b'5' => {
                // Directory
                std::fs::create_dir_all(&dest)?;
                skip_tar_data(&mut reader, size)?;
            }
            b'2' => {
                // Symlink
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                #[cfg(unix)]
                std::os::unix::fs::symlink(&linkname, &dest)?;
                skip_tar_data(&mut reader, size)?;
            }
            b'1' => {
                // Hard link — create as symlink on Redox (no hard link support)
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let link_target = match &prefix_to_strip {
                    Some(pfx) => linkname.strip_prefix(pfx).unwrap_or(&linkname).to_string(),
                    None => linkname.clone(),
                };
                // Hard link target is relative to the archive root
                let target_path = out_path.join(&link_target);
                if target_path.exists() {
                    std::fs::copy(&target_path, &dest)?;
                }
                skip_tar_data(&mut reader, size)?;
            }
            _ => {
                // Skip unknown entry types (long names, etc.)
                skip_tar_data(&mut reader, size)?;
            }
        }
    }

    Ok(())
}

/// Parse a null-terminated string from a tar header field.
fn parse_tar_string(field: &[u8]) -> String {
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    String::from_utf8_lossy(&field[..end]).to_string()
}

/// Parse an octal number from a tar header field.
fn parse_tar_octal(field: &[u8]) -> u64 {
    let s = parse_tar_string(field);
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }
    u64::from_str_radix(s, 8).unwrap_or(0)
}

/// Skip `n` bytes in a reader (used for tar data blocks and padding).
fn skip_tar_data<R: std::io::Read>(
    reader: &mut R,
    n: u64,
) -> Result<(), std::io::Error> {
    let mut remaining = n;
    let mut buf = [0u8; 4096];
    while remaining > 0 {
        let to_read = std::cmp::min(remaining as usize, buf.len());
        std::io::Read::read_exact(reader, &mut buf[..to_read])?;
        remaining -= to_read as u64;
    }
    Ok(())
}

// ── Hash verification for FODs ─────────────────────────────────────────────

/// Verify the content hash of a fetched output against the declared hash.
///
/// For flat mode: SHA-256 of the file content.
/// For recursive mode: SHA-256 of the NAR serialization.
pub fn verify_fetch_hash(
    drv: &nix_compat::derivation::Derivation,
    out_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let output = drv
        .outputs
        .get("out")
        .ok_or("no 'out' output in derivation")?;

    let ca_hash = match &output.ca_hash {
        Some(h) => h,
        None => return Ok(()), // No hash to verify (impure)
    };

    let path = std::path::Path::new(out_path);

    match ca_hash {
        CAHash::Flat(expected) => {
            // Hash the raw file content
            use sha2::{Digest, Sha256};
            let content = std::fs::read(path)?;
            let actual = Sha256::digest(&content);
            let expected_bytes = match expected {
                NixHash::Sha256(h) => h,
                _ => return Err("fetchurl only supports SHA-256".into()),
            };
            if actual.as_slice() != expected_bytes {
                return Err(format!(
                    "hash mismatch for {}:\n  expected: {}\n  got:      {}",
                    out_path,
                    data_encoding::HEXLOWER.encode(expected_bytes),
                    data_encoding::HEXLOWER.encode(actual.as_slice()),
                )
                .into());
            }
        }
        CAHash::Nar(expected) => {
            // Hash the NAR serialization
            let (nar_hash_str, _) = crate::local_build::nar_hash_path(path)?;
            let actual_hex = nar_hash_str
                .strip_prefix("sha256:")
                .ok_or("unexpected hash format")?;
            let expected_bytes = match expected {
                NixHash::Sha256(h) => h,
                _ => return Err("fetchurl only supports SHA-256".into()),
            };
            let expected_hex = data_encoding::HEXLOWER.encode(expected_bytes);
            if actual_hex != expected_hex {
                return Err(format!(
                    "hash mismatch (NAR) for {}:\n  expected: {}\n  got:      {}",
                    out_path, expected_hex, actual_hex,
                )
                .into());
            }
        }
        _ => {
            return Err("unsupported CA hash type".into());
        }
    }

    Ok(())
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── url_basename ───────────────────────────────────────────────────

    #[test]
    fn basename_simple_url() {
        assert_eq!(url_basename("https://example.com/file.txt"), "file.txt");
    }

    #[test]
    fn basename_with_path() {
        assert_eq!(
            url_basename("https://example.com/dir/subdir/archive.tar.gz"),
            "archive.tar.gz"
        );
    }

    #[test]
    fn basename_with_query() {
        assert_eq!(
            url_basename("https://example.com/file.txt?v=2"),
            "file.txt"
        );
    }

    #[test]
    fn basename_with_fragment() {
        assert_eq!(
            url_basename("https://example.com/file.txt#section"),
            "file.txt"
        );
    }

    #[test]
    fn basename_trailing_slash() {
        assert_eq!(url_basename("https://example.com/dir/"), "source");
    }

    #[test]
    fn basename_no_path() {
        assert_eq!(url_basename("https://example.com"), "example.com");
    }

    #[test]
    fn basename_github_tarball() {
        assert_eq!(
            url_basename("https://github.com/owner/repo/archive/v1.0.tar.gz"),
            "v1.0.tar.gz"
        );
    }

    // ── sanitize_name ──────────────────────────────────────────────────

    #[test]
    fn sanitize_passthrough() {
        assert_eq!(sanitize_name("hello-world.tar.gz"), "hello-world.tar.gz");
    }

    #[test]
    fn sanitize_special_chars() {
        assert_eq!(sanitize_name("file (1).txt"), "file--1-.txt");
    }

    #[test]
    fn sanitize_dot_prefix() {
        assert_eq!(sanitize_name(".hidden"), "_hidden");
    }

    // ── tar parsing ────────────────────────────────────────────────────

    #[test]
    fn parse_tar_string_simple() {
        let mut field = [0u8; 100];
        field[..5].copy_from_slice(b"hello");
        assert_eq!(parse_tar_string(&field), "hello");
    }

    #[test]
    fn parse_tar_string_full() {
        let field = [b'x'; 100];
        assert_eq!(parse_tar_string(&field), "x".repeat(100));
    }

    #[test]
    fn parse_tar_octal_valid() {
        let mut field = [0u8; 12];
        field[..7].copy_from_slice(b"0000644");
        assert_eq!(parse_tar_octal(&field), 0o644);
    }

    #[test]
    fn parse_tar_octal_size() {
        let mut field = [0u8; 12];
        field[..11].copy_from_slice(b"00000001234");
        assert_eq!(parse_tar_octal(&field), 0o1234);
    }

    #[test]
    fn parse_tar_octal_empty() {
        let field = [0u8; 12];
        assert_eq!(parse_tar_octal(&field), 0);
    }

    // ── tar extraction ─────────────────────────────────────────────────

    #[test]
    fn extract_tar_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("output");

        // Empty tar: two zero blocks (1024 bytes of zeros)
        let data = vec![0u8; 1024];
        let result = extract_tar(std::io::Cursor::new(data), out.to_str().unwrap());
        assert!(result.is_ok());
        assert!(out.is_dir());
    }

    // ── make_fetch_derivation ──────────────────────────────────────────

    #[test]
    fn fetch_drv_basic() {
        use crate::known_paths::KnownPaths;
        use std::cell::RefCell;

        let state = SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        };

        let result = make_fetch_derivation(
            &state,
            "https://example.com/hello.txt",
            "hello.txt",
            Some("sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="),
            false,
        );

        assert!(result.is_ok(), "error: {:?}", result.err());
        let val = result.unwrap();
        let s = format!("{val}");
        assert!(s.starts_with("\"/nix/store/"), "got: {s}");
        assert!(s.contains("-hello.txt\""), "got: {s}");
    }

    #[test]
    fn fetch_drv_same_hash_same_path() {
        use crate::known_paths::KnownPaths;
        use std::cell::RefCell;

        let state = SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        };

        let hash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=";

        let r1 = make_fetch_derivation(&state, "https://a.com/f", "f", Some(hash), false)
            .unwrap();
        let r2 = make_fetch_derivation(&state, "https://b.com/f", "f", Some(hash), false)
            .unwrap();

        // Same hash + same name = same output path (FOD property)
        assert_eq!(format!("{r1}"), format!("{r2}"));
    }

    #[test]
    fn fetch_drv_different_hash_different_path() {
        use crate::known_paths::KnownPaths;
        use std::cell::RefCell;

        let state = SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        };

        let r1 = make_fetch_derivation(
            &state,
            "https://a.com/f",
            "f",
            Some("sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="),
            false,
        )
        .unwrap();

        let r2 = make_fetch_derivation(
            &state,
            "https://a.com/f",
            "f",
            Some("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
            false,
        )
        .unwrap();

        assert_ne!(format!("{r1}"), format!("{r2}"));
    }

    #[test]
    fn fetch_drv_requires_hash() {
        use crate::known_paths::KnownPaths;
        use std::cell::RefCell;

        let state = SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        };

        let result =
            make_fetch_derivation(&state, "https://a.com/f", "f", None, false);
        assert!(result.is_err());
    }

    #[test]
    fn fetch_drv_unpack_mode() {
        use crate::known_paths::KnownPaths;
        use std::cell::RefCell;

        let state = SnixRedoxState {
            known_paths: RefCell::new(KnownPaths::default()),
        };

        let hash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=";

        let flat = make_fetch_derivation(&state, "https://a.com/f", "f", Some(hash), false)
            .unwrap();
        let unpack = make_fetch_derivation(&state, "https://a.com/f", "f", Some(hash), true)
            .unwrap();

        // Different hash modes → different output paths
        assert_ne!(format!("{flat}"), format!("{unpack}"));
    }

    // ── eval integration ───────────────────────────────────────────────

    #[test]
    fn eval_fetchurl_creates_store_path() {
        let result = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://example.com/test.txt"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }"#,
        );
        assert!(result.is_ok(), "error: {:?}", result.err());
        let (path, _state) = result.unwrap();
        assert!(path.starts_with("\"/nix/store/"), "got: {path}");
        assert!(path.contains("-test.txt\""), "got: {path}");
    }

    #[test]
    fn eval_fetchurl_registered_in_known_paths() {
        // builtins.fetchurl returns a string (store path), not a derivation attrset.
        // Evaluate it and check that the derivation was registered in KnownPaths.
        let (path, state) = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://example.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }"#,
        ).unwrap();

        assert!(path.starts_with("\"/nix/store/"), "got: {path}");

        let kp = state.known_paths.borrow();
        // Should have exactly one derivation registered
        assert_eq!(kp.get_derivations().count(), 1);

        // The derivation should have builder = "builtin:fetchurl"
        let (_, drv) = kp.get_derivations().next().unwrap();
        assert_eq!(drv.builder, "builtin:fetchurl");
        assert_eq!(drv.system, "builtin");
    }

    #[test]
    fn eval_fetchtarball_creates_store_path() {
        let result = crate::eval::evaluate_with_state(
            r#"builtins.fetchTarball { url = "https://example.com/src.tar.gz"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }"#,
        );
        assert!(result.is_ok(), "error: {:?}", result.err());
        let (path, _) = result.unwrap();
        assert!(path.starts_with("\"/nix/store/"), "got: {path}");
    }

    #[test]
    fn eval_fetchurl_as_drv_input() {
        // fetchurl result can be used as input to another derivation
        let result = crate::eval::evaluate_with_state(
            r#"
            let
              src = builtins.fetchurl {
                url = "https://example.com/src.c";
                sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=";
              };
            in (derivation {
              name = "uses-fetch";
              builder = "/bin/sh";
              system = "x86_64-linux";
              inherit src;
            }).outPath
            "#,
        );
        assert!(result.is_ok(), "error: {:?}", result.err());
        let (path, state) = result.unwrap();
        assert!(path.contains("-uses-fetch\""), "got: {path}");

        // Should have 2 derivations: the fetch + the user
        let kp = state.known_paths.borrow();
        assert_eq!(kp.get_derivations().count(), 2);
    }

    #[test]
    fn eval_fetchurl_fod_same_hash_is_deterministic() {
        let (path1, _) = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://mirror1.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }"#,
        ).unwrap();

        let (path2, _) = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://mirror2.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }"#,
        ).unwrap();

        // FOD property: same name + same hash → same store path
        assert_eq!(path1, path2);
    }
}
