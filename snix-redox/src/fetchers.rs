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
/// Extract a tar archive to a directory using the `tar` crate.
///
/// Strips the top-level directory component (like GitHub release tarballs
/// where all entries are under `project-v1.0/`).
fn extract_tar<R: std::io::Read>(
    reader: R,
    out: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let out_path = std::path::Path::new(out);
    std::fs::create_dir_all(out_path)?;

    let mut archive = tar::Archive::new(reader);
    // Don't preserve mtime — matches Nix's deterministic store semantics.
    archive.set_preserve_mtime(false);

    // Detect the top-level prefix to strip from the first entry.
    // We collect entries, find the common prefix, then extract with
    // path rewriting. Since tar::Archive is streaming, we need to
    // iterate entries one by one.
    let mut prefix_to_strip: Option<std::path::PathBuf> = None;

    for entry_result in archive.entries()? {
        let mut entry = entry_result?;
        let entry_path = entry.path()?.into_owned();

        // Determine prefix from first non-empty entry.
        if prefix_to_strip.is_none() {
            if let Some(first_component) = entry_path.components().next() {
                prefix_to_strip = Some(std::path::PathBuf::from(first_component.as_os_str()));
            }
        }

        // Strip the top-level prefix.
        let relative = match &prefix_to_strip {
            Some(pfx) => match entry_path.strip_prefix(pfx) {
                Ok(stripped) => stripped.to_path_buf(),
                Err(_) => entry_path.clone(),
            },
            None => entry_path.clone(),
        };

        // Skip the top-level directory entry itself (empty after stripping).
        if relative.as_os_str().is_empty() || relative == std::path::Path::new(".") {
            continue;
        }

        let dest = out_path.join(&relative);

        match entry.header().entry_type() {
            tar::EntryType::Regular | tar::EntryType::GNUSparse => {
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let mut file = std::fs::File::create(&dest)?;
                std::io::copy(&mut entry, &mut file)?;

                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(mode) = entry.header().mode() {
                        let _ = std::fs::set_permissions(
                            &dest,
                            std::fs::Permissions::from_mode(mode),
                        );
                    }
                }
            }
            tar::EntryType::Directory => {
                std::fs::create_dir_all(&dest)?;
            }
            tar::EntryType::Symlink => {
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                #[cfg(unix)]
                if let Some(target) = entry.link_name()? {
                    std::os::unix::fs::symlink(target.as_ref(), &dest)?;
                }
            }
            tar::EntryType::Link => {
                // Hard link — copy the target file's contents.
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                if let Some(link_target) = entry.link_name()? {
                    let stripped_target = match &prefix_to_strip {
                        Some(pfx) => link_target
                            .strip_prefix(pfx.as_path())
                            .unwrap_or(link_target.as_ref())
                            .to_path_buf(),
                        None => link_target.into_owned(),
                    };
                    let target_path = out_path.join(&stripped_target);
                    if target_path.exists() {
                        std::fs::copy(&target_path, &dest)?;
                    }
                }
            }
            _ => {
                // Skip unknown entry types (pax headers, etc.)
            }
        }
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
    fn extract_tar_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("output");
        // An empty tar is just 1024 zero bytes (two 512-byte end-of-archive markers).
        let data = vec![0u8; 1024];
        let result = extract_tar(std::io::Cursor::new(data), out.to_str().unwrap());
        assert!(result.is_ok());
        assert!(out.is_dir());
    }

    #[test]
    fn extract_tar_with_file() {
        let tmp_src = tempfile::tempdir().unwrap();
        let inner_dir = tmp_src.path().join("project-v1");
        std::fs::create_dir(&inner_dir).unwrap();
        std::fs::write(inner_dir.join("hello.txt"), "hello world").unwrap();

        // Build a tar in memory
        let mut builder = tar::Builder::new(Vec::new());
        builder
            .append_dir_all("project-v1", &inner_dir)
            .unwrap();
        let tar_data = builder.into_inner().unwrap();

        let tmp_out = tempfile::tempdir().unwrap();
        let out = tmp_out.path().join("extracted");
        extract_tar(std::io::Cursor::new(tar_data), out.to_str().unwrap()).unwrap();

        // Top-level "project-v1/" should be stripped
        assert!(out.join("hello.txt").exists());
        assert_eq!(
            std::fs::read_to_string(out.join("hello.txt")).unwrap(),
            "hello world"
        );
    }

    #[test]
    fn extract_tar_strips_prefix() {
        let tmp_src = tempfile::tempdir().unwrap();
        let inner = tmp_src.path().join("nixpkgs-abc123");
        std::fs::create_dir_all(inner.join("pkgs/tools")).unwrap();
        std::fs::write(inner.join("pkgs/tools/rg.nix"), "{ }").unwrap();

        let mut builder = tar::Builder::new(Vec::new());
        builder.append_dir_all("nixpkgs-abc123", &inner).unwrap();
        let tar_data = builder.into_inner().unwrap();

        let tmp_out = tempfile::tempdir().unwrap();
        let out = tmp_out.path().join("extracted");
        extract_tar(std::io::Cursor::new(tar_data), out.to_str().unwrap()).unwrap();

        // "nixpkgs-abc123/" stripped, nested structure preserved
        assert!(out.join("pkgs/tools/rg.nix").exists());
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
