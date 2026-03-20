//! Build-time fetcher execution and hash verification.
//!
//! The fetcher *builtins* (`builtins.fetchurl`, `builtins.fetchTarball`) are
//! provided by upstream `snix-glue`. This module handles the build-time
//! side: downloading URLs, extracting tarballs, and verifying content hashes
//! when a derivation with `builder = "builtin:fetchurl"` is executed.

use nix_compat::nixhash::{CAHash, NixHash};

// ── Build-time fetcher execution ───────────────────────────────────────────

/// Download a URL and write the content to a file.
///
/// Called from [`local_build::build_derivation`] when the builder is
/// `"builtin:fetchurl"`. Reads `url` from the derivation environment.
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
pub fn fetch_and_unpack(url: &str, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    let resp = ureq::get(url).call()?;
    let reader = resp.into_body().into_reader();

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
        let mut compressed = Vec::new();
        std::io::Read::read_to_end(&mut std::io::BufReader::new(reader), &mut compressed)?;
        if compressed.len() >= 2 && compressed[0] == 0x1f && compressed[1] == 0x8b {
            Box::new(flate2::read::GzDecoder::new(std::io::Cursor::new(compressed)))
        } else {
            Box::new(std::io::Cursor::new(compressed))
        }
    };

    extract_tar(decompressed, out)?;
    Ok(())
}

/// Extract a tar archive to a directory.
///
/// Strips the top-level directory component (like GitHub release tarballs).
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
        match std::io::Read::read_exact(&mut reader, &mut header_buf) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e.into()),
        }

        if header_buf.iter().all(|&b| b == 0) {
            break;
        }

        let name = parse_tar_string(&header_buf[0..100]);
        let mode = parse_tar_octal(&header_buf[100..108]);
        let size = parse_tar_octal(&header_buf[124..136]) as u64;
        let typeflag = header_buf[156];
        let linkname = parse_tar_string(&header_buf[157..257]);
        let prefix = parse_tar_string(&header_buf[345..500]);
        let full_name = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };

        if prefix_to_strip.is_none() && !full_name.is_empty() {
            let first_component = full_name.split('/').next().unwrap_or("");
            if !first_component.is_empty() {
                prefix_to_strip = Some(format!("{first_component}/"));
            }
        }

        let relative_name = match &prefix_to_strip {
            Some(pfx) => full_name.strip_prefix(pfx).unwrap_or(&full_name),
            None => &full_name,
        };

        if relative_name.is_empty() || relative_name == "." {
            skip_tar_data(&mut reader, size)?;
            continue;
        }

        let dest = out_path.join(relative_name);

        match typeflag {
            b'0' | 0 => {
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
                let padding = (512 - (size % 512)) % 512;
                skip_tar_data(&mut reader, padding)?;

                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let perms = std::fs::Permissions::from_mode(mode as u32);
                    let _ = std::fs::set_permissions(&dest, perms);
                }
            }
            b'5' => {
                std::fs::create_dir_all(&dest)?;
                skip_tar_data(&mut reader, size)?;
            }
            b'2' => {
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                #[cfg(unix)]
                std::os::unix::fs::symlink(&linkname, &dest)?;
                skip_tar_data(&mut reader, size)?;
            }
            b'1' => {
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let link_target = match &prefix_to_strip {
                    Some(pfx) => linkname.strip_prefix(pfx).unwrap_or(&linkname).to_string(),
                    None => linkname.clone(),
                };
                let target_path = out_path.join(&link_target);
                if target_path.exists() {
                    std::fs::copy(&target_path, &dest)?;
                }
                skip_tar_data(&mut reader, size)?;
            }
            _ => {
                skip_tar_data(&mut reader, size)?;
            }
        }
    }

    Ok(())
}

fn parse_tar_string(field: &[u8]) -> String {
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    String::from_utf8_lossy(&field[..end]).to_string()
}

fn parse_tar_octal(field: &[u8]) -> u64 {
    let s = parse_tar_string(field);
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }
    u64::from_str_radix(s, 8).unwrap_or(0)
}

fn skip_tar_data<R: std::io::Read>(reader: &mut R, n: u64) -> Result<(), std::io::Error> {
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
        None => return Ok(()),
    };

    let path = std::path::Path::new(out_path);

    match ca_hash {
        CAHash::Flat(expected) => {
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

    #[test]
    fn extract_tar_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("output");
        let data = vec![0u8; 1024];
        let result = extract_tar(std::io::Cursor::new(data), out.to_str().unwrap());
        assert!(result.is_ok());
        assert!(out.is_dir());
    }

    // ── eval integration (upstream builtins) ───────────────────────────

    #[test]
    fn eval_fetchurl_creates_store_path() {
        let result = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://example.com/test.txt"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }"#,
        );
        assert!(result.is_ok(), "error: {:?}", result.err());
        let (path, _io) = result.unwrap();
        // Upstream fetchurl returns a path value (not string), so the
        // formatted result may or may not have surrounding quotes.
        let clean = path.trim_matches('"');
        assert!(clean.starts_with("/nix/store/"), "got: {path}");
    }

    #[test]
    fn eval_fetchtarball_creates_store_path() {
        let result = crate::eval::evaluate_with_state(
            r#"builtins.fetchTarball { url = "https://example.com/src.tar.gz"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }"#,
        );
        assert!(result.is_ok(), "error: {:?}", result.err());
        let (path, _) = result.unwrap();
        let clean = path.trim_matches('"');
        assert!(clean.starts_with("/nix/store/"), "got: {path}");
    }

    #[test]
    fn eval_fetchurl_fod_same_hash_is_deterministic() {
        let (path1, _) = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://mirror1.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }"#,
        ).unwrap();

        let (path2, _) = crate::eval::evaluate_with_state(
            r#"builtins.fetchurl { url = "https://mirror2.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }"#,
        ).unwrap();

        assert_eq!(path1, path2);
    }
}
