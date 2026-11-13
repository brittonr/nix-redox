//! Build-time fetcher execution and hash verification.
//!
//! The fetcher *builtins* (`builtins.fetchurl`, `builtins.fetchTarball`) are
//! provided by upstream `snix-glue`. This module handles the build-time
//! side: downloading URLs, extracting tarballs, and verifying content hashes
//! when a derivation with `builder = "builtin:fetchurl"` is executed.
//!
//! Derivation parsing uses upstream `snix_glue::fetchurl::fetchurl_derivation_to_fetch()`
//! which returns a typed `Fetch` enum. Download execution is sync via ureq.

use nix_compat::nixhash::NixHash;
use snix_glue::fetchers::Fetch;
use snix_glue::fetchurl::fetchurl_derivation_to_fetch;

// ── Build-time fetcher execution ───────────────────────────────────────────

/// Download a URL and write the content to the output path.
///
/// Called from [`local_build::build_derivation`] when the builder is
/// `"builtin:fetchurl"`. Uses upstream `fetchurl_derivation_to_fetch()` to
/// parse the derivation into a typed `Fetch`, then dispatches to sync
/// download routines.
pub fn fetch_to_store(
    drv: &nix_compat::derivation::Derivation,
) -> Result<(), Box<dyn std::error::Error>> {
    // Parse derivation → typed Fetch (validates builder, system, outputs, URL).
    let (_name, fetch) = fetchurl_derivation_to_fetch(drv)?;

    let out = drv
        .environment
        .get("out")
        .ok_or("builtin:fetchurl: 'out' not set in environment")?
        .to_string();

    if let Some(parent) = std::path::Path::new(&out).parent() {
        std::fs::create_dir_all(parent)?;
    }

    // The Fetch variant determines the download mode. However, upstream
    // maps `unpack=1` derivations to Fetch::NAR (since the hash is NAR),
    // but the URL is actually a tarball. Check `unpack` directly.
    let unpack = drv.environment.get("unpack").is_some_and(|v| v == "1");

    match &fetch {
        Fetch::URL { url, .. } => {
            eprintln!("fetching {url}...");
            fetch_flat(url.as_str(), &out)?;
        }
        Fetch::Tarball { url, .. } => {
            eprintln!("fetching tarball {url}...");
            fetch_and_unpack(url.as_str(), &out)?;
        }
        Fetch::NAR { url, .. } if unpack => {
            eprintln!("fetching tarball {url}...");
            fetch_and_unpack(url.as_str(), &out)?;
        }
        Fetch::NAR { url, .. } => {
            // NAR download (e.g., from binary cache nar/ URL)
            eprintln!("fetching NAR {url}...");
            fetch_nar(url.as_str(), &out)?;
        }
        Fetch::Executable { url, .. } => {
            eprintln!("fetching executable {url}...");
            fetch_flat(url.as_str(), &out)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let perms = std::fs::Permissions::from_mode(0o755);
                std::fs::set_permissions(&out, perms)?;
            }
        }
        Fetch::Git() => {
            return Err("builtin:fetchurl: git fetches not supported".into());
        }
    }

    eprintln!("✓ fetched to {out}");
    Ok(())
}

/// Verify the content hash of a fetched output against the expected hash
/// from the `Fetch` variant.
pub fn verify_fetch_hash(
    drv: &nix_compat::derivation::Derivation,
    out_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let (_name, fetch) = fetchurl_derivation_to_fetch(drv)?;

    match &fetch {
        Fetch::URL {
            exp_hash: Some(expected),
            ..
        } => verify_flat_hash(out_path, expected),

        Fetch::URL { exp_hash: None, .. } => Ok(()),

        Fetch::Tarball {
            exp_nar_sha256: Some(expected),
            ..
        } => {
            let expected_hash = NixHash::Sha256(*expected);
            verify_nar_hash(out_path, &expected_hash)
        }

        Fetch::Tarball {
            exp_nar_sha256: None,
            ..
        } => Ok(()),

        Fetch::NAR { hash, .. } | Fetch::Executable { hash, .. } => verify_nar_hash(out_path, hash),

        Fetch::Git() => Ok(()),
    }
}

// ── Hash verification helpers ──────────────────────────────────────────────

/// Verify the flat (content) hash of a file.
fn verify_flat_hash(out_path: &str, expected: &NixHash) -> Result<(), Box<dyn std::error::Error>> {
    use sha2::{Digest, Sha256};
    let content = std::fs::read(out_path)?;
    let actual = Sha256::digest(&content);
    let expected_bytes = match expected {
        NixHash::Sha256(h) => h,
        _ => return Err("fetchurl only supports SHA-256 for flat hashes".into()),
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
    Ok(())
}

/// Verify the NAR hash of a path (file or directory).
fn verify_nar_hash(out_path: &str, expected: &NixHash) -> Result<(), Box<dyn std::error::Error>> {
    let path = std::path::Path::new(out_path);
    let (nar_hash_str, _) = crate::local_build::nar_hash_path(path)?;
    let actual_hex = nar_hash_str
        .strip_prefix("sha256:")
        .ok_or("unexpected hash format")?;
    let expected_bytes = match expected {
        NixHash::Sha256(h) => h,
        _ => return Err("fetchurl only supports SHA-256 for NAR hashes".into()),
    };
    let expected_hex = data_encoding::HEXLOWER.encode(expected_bytes);
    if actual_hex != expected_hex {
        return Err(format!(
            "hash mismatch (NAR) for {}:\n  expected: {}\n  got:      {}",
            out_path, expected_hex, actual_hex,
        )
        .into());
    }
    Ok(())
}

// ── Git fetch (via git CLI) ─────────────────────────────────────────────────

/// Clone a git repository and checkout a specific revision to a store path.
///
/// Shells out to the `git` binary (must be in PATH or at a known location).
/// The `.git` directory is stripped from the output.
///
/// If `nar_hash_sri` is provided, verifies the NAR hash of the output.
/// If the store path already exists, returns immediately (cached).
pub fn fetch_git(
    url: &str,
    rev: &str,
    out: &str,
    nar_hash_sri: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Cache check: if output already exists, skip
    if std::path::Path::new(out).exists() {
        eprintln!("using cached git fetch at {out}");
        return Ok(());
    }

    fetch_git_checkout(url, rev, out, false, false)?;

    // Verify NAR hash if provided
    if let Some(expected_sri) = nar_hash_sri {
        verify_nar_hash_sri(out, expected_sri)?;
    }

    eprintln!(
        "✓ fetched git {url} @ {} to {out}",
        &rev[..std::cmp::min(rev.len(), 12)]
    );
    Ok(())
}

/// Fetch a revision into a fresh staging path, returning its immutable commit ID.
/// Submodules and LFS are handled by native git (and git-lfs when requested).
pub(crate) fn fetch_git_checkout(
    url: &str,
    rev: &str,
    out: &str,
    submodules: bool,
    lfs: bool,
) -> Result<String, Box<dyn std::error::Error>> {
    if rev.is_empty() || rev.starts_with('-') || rev.chars().any(char::is_whitespace) {
        return Err("git revision must be a nonempty ref or commit ID, not an option".into());
    }
    if std::path::Path::new(out).symlink_metadata().is_ok() {
        return Err("git checkout destination already exists".into());
    }
    let git = find_git()?;
    let command = |args: &[&str], cwd: Option<&str>| {
        let mut command = std::process::Command::new(&git);
        command
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_LFS_SKIP_SMUDGE", "1");
        if let Some(cwd) = cwd {
            command.current_dir(cwd);
        }
        command
    };
    let run = |args: &[&str], cwd: Option<&str>| -> Result<String, Box<dyn std::error::Error>> {
        let output = command(args, cwd).output()?;
        if !output.status.success() {
            return Err(format!(
                "git {} failed: {}",
                args[0],
                String::from_utf8_lossy(&output.stderr)
            )
            .into());
        }
        let mut stdout = String::from_utf8(output.stdout)?;
        stdout.truncate(stdout.trim_end().len());
        Ok(stdout)
    };
    let result = (|| {
        let pinned = (rev.len() == 40 || rev.len() == 64)
            && rev.bytes().all(|byte| byte.is_ascii_hexdigit());
        // Depth-one clones cannot resolve pinned ancestors on servers that
        // reject unadvertised SHA requests. Named refs can remain shallow.
        if pinned {
            run(&["clone", "--no-checkout", "--", url, out], None)?;
        } else {
            run(
                &["clone", "--depth", "1", "--no-checkout", "--", url, out],
                None,
            )?;
        }
        let local_commit = if pinned {
            let expression = format!("{rev}^{{commit}}");
            let output = command(
                &["rev-parse", "--verify", "--quiet", &expression],
                Some(out),
            )
            .output()?;
            match output.status.code() {
                Some(0) => {
                    let mut commit = String::from_utf8(output.stdout)?;
                    commit.truncate(commit.trim_end().len());
                    Some(commit)
                }
                Some(1) => None,
                _ => {
                    return Err(format!(
                        "git revision lookup failed: {}",
                        String::from_utf8_lossy(&output.stderr)
                    )
                    .into())
                }
            }
        } else {
            None
        };
        let commit = match local_commit {
            Some(commit) => commit,
            None => {
                run(&["fetch", "--depth", "1", "origin", rev], Some(out))?;
                run(&["rev-parse", "--verify", "FETCH_HEAD^{commit}"], Some(out))?
            }
        };
        if !(commit.len() == 40 || commit.len() == 64)
            || !commit.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("git returned an invalid commit ID".into());
        }
        run(&["checkout", "--detach", &commit], Some(out))?;
        if submodules {
            run(&["submodule", "update", "--init", "--recursive"], Some(out))?;
        }
        if lfs {
            run(&["lfs", "fetch", "origin", &commit], Some(out))?;
            run(&["lfs", "checkout"], Some(out))?;
            if submodules {
                run(
                    &["submodule", "foreach", "--recursive", "git lfs pull"],
                    Some(out),
                )?;
            }
        }
        remove_git_metadata(std::path::Path::new(out))?;
        Ok(commit)
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(out);
    }
    result
}

fn remove_git_metadata(path: &std::path::Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        if entry.file_name() == ".git" {
            if ty.is_dir() { std::fs::remove_dir_all(entry.path())?; }
            else { std::fs::remove_file(entry.path())?; }
        } else if ty.is_dir() {
            remove_git_metadata(&entry.path())?;
        }
    }
    Ok(())
}

/// Resolve a git ref (branch/tag) to a commit hash via `git ls-remote`.
pub fn resolve_git_ref(url: &str, ref_name: &str) -> Result<String, Box<dyn std::error::Error>> {
    let git = find_git()?;
    let output = std::process::Command::new(&git)
        .args(["ls-remote", url, ref_name])
        .output()
        .map_err(|e| format!("failed to run git ls-remote: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("git ls-remote failed for '{url}' ref '{ref_name}':\n{stderr}").into());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    // ls-remote output: "<hash>\t<ref>\n"
    let hash = stdout
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().next())
        .ok_or_else(|| {
            format!("git ls-remote returned no results for ref '{ref_name}' at '{url}'")
        })?;

    Ok(hash.to_string())
}

/// Verify NAR hash of a path against an SRI hash string.
fn verify_nar_hash_sri(
    out_path: &str,
    expected_sri: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    use nix_compat::nixhash::{HashAlgo, NixHash};

    let expected = NixHash::from_str(expected_sri, Some(HashAlgo::Sha256))
        .map_err(|e| format!("invalid expected hash: {e}"))?;

    let (actual_hash_str, _size) =
        crate::local_build::nar_hash_path(std::path::Path::new(out_path))?;

    let actual_hex = actual_hash_str
        .strip_prefix("sha256:")
        .ok_or("unexpected hash format from nar_hash_path")?;

    let expected_bytes = match &expected {
        NixHash::Sha256(h) => h,
        _ => return Err("only SHA-256 hashes supported for fetchGit".into()),
    };
    let expected_hex = data_encoding::HEXLOWER.encode(expected_bytes);

    if actual_hex != expected_hex {
        let _ = std::fs::remove_dir_all(out_path);
        return Err(format!(
            "NAR hash mismatch for fetchGit output {}:\n  expected: {}\n  got:      {}",
            out_path, expected_hex, actual_hex
        )
        .into());
    }

    Ok(())
}

/// Find the git binary.
fn find_git() -> Result<String, Box<dyn std::error::Error>> {
    // Check common locations on Redox and standard paths
    for path in ["/nix/system/profile/bin/git", "/usr/bin/git", "/bin/git"] {
        if std::path::Path::new(path).exists() {
            return Ok(path.to_string());
        }
    }
    // Fall back to PATH lookup
    let which = std::process::Command::new("which").arg("git").output();
    if let Ok(out) = which {
        if out.status.success() {
            let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !path.is_empty() {
                return Ok(path);
            }
        }
    }
    Err("git command not found — install git to use fetchGit".into())
}

// ── Download helpers (sync, ureq-based) ────────────────────────────────────

/// Download a URL (including local file URLs) in flat mode.
pub(crate) fn fetch_flat(url: &str, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut reader = open_url(url)?;
    let mut file = std::fs::File::create(out)?;
    std::io::copy(&mut reader, &mut file)?;
    Ok(())
}

fn open_url(url: &str) -> Result<Box<dyn std::io::Read + Send>, Box<dyn std::error::Error>> {
    if url.starts_with("file:") {
        // Let the upstream Fetch variant supply its URL type without a second parser.
        let fetch = Fetch::URL { url: url.parse()?, exp_hash: None };
        let Fetch::URL { url: parsed, .. } = fetch else { unreachable!() };
        let path = parsed.to_file_path().map_err(|_| "file URL must have a local absolute path")?;
        return Ok(Box::new(std::fs::File::open(path)?));
    }
    let response = ureq::get(url).call()?;
    Ok(Box::new(response.into_body().into_reader()))
}

/// Download a NAR file from a URL and extract it.
///
/// The URL may point to a compressed NAR (.nar.xz, .nar.zst, etc.).
fn fetch_nar(url: &str, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    let resp = ureq::get(url).call()?;
    let reader = resp.into_body().into_reader();

    let decompressed: Box<dyn std::io::Read + Send> = decompress_reader(url, reader)?;
    let mut buf_reader = std::io::BufReader::new(decompressed);
    crate::nar::extract(&mut buf_reader, out)?;
    Ok(())
}

/// Download a tarball, decompress, and extract to a directory (unpack mode).
///
/// Supports `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`, and plain `.tar`.
pub fn fetch_and_unpack(url: &str, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    let reader = open_url(url)?;

    let decompressed: Box<dyn std::io::Read + Send> = decompress_reader(url, reader)?;
    extract_tar(decompressed, out)?;
    Ok(())
}

/// Select a decompressor based on URL suffix.
fn decompress_reader(
    url: &str,
    reader: impl std::io::Read + Send + 'static,
) -> Result<Box<dyn std::io::Read + Send>, Box<dyn std::error::Error>> {
    let url = url.split(['?', '#']).next().unwrap_or(url);
    if url.ends_with(".gz") || url.ends_with(".tgz") {
        Ok(Box::new(flate2::read::GzDecoder::new(reader)))
    } else if url.ends_with(".xz") || url.ends_with(".txz") {
        let mut input = std::io::BufReader::new(reader);
        let mut output = Vec::new();
        lzma_rs::xz_decompress(&mut input, &mut output)
            .map_err(|e| format!("xz decompression failed: {e}"))?;
        Ok(Box::new(std::io::Cursor::new(output)))
    } else if url.ends_with(".bz2") || url.ends_with(".tbz2") {
        Ok(Box::new(bzip2_rs::DecoderReader::new(reader)))
    } else if url.ends_with(".zst") || url.ends_with(".zstd") {
        Ok(Box::new(
            ruzstd::decoding::StreamingDecoder::new(reader)
                .map_err(|e| format!("zstd decompression failed: {e}"))?,
        ))
    } else if url.ends_with(".tar") || url.ends_with(".nar") {
        Ok(Box::new(reader))
    } else {
        // Unknown suffix — try gzip magic, fall back to raw.
        let mut compressed = Vec::new();
        std::io::Read::read_to_end(&mut std::io::BufReader::new(reader), &mut compressed)?;
        if compressed.len() >= 2 && compressed[0] == 0x1f && compressed[1] == 0x8b {
            Ok(Box::new(flate2::read::GzDecoder::new(
                std::io::Cursor::new(compressed),
            )))
        } else {
            Ok(Box::new(std::io::Cursor::new(compressed)))
        }
    }
}

/// Extract a tar archive to a directory using the `tar` crate.
///
/// Strips the top-level directory component (like GitHub release tarballs
/// where all entries are under `project-v1.0/`).
fn extract_tar<R: std::io::Read>(reader: R, out: &str) -> Result<(), Box<dyn std::error::Error>> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let out = std::path::Path::new(out);
    if out.symlink_metadata().is_ok() {
        return Err(format!("refusing to unpack over existing path {}", out.display()).into());
    }
    let parent = out.parent().ok_or("unpack destination has no parent")?;
    std::fs::create_dir_all(parent)?;
    let staging = loop {
        let candidate = parent.join(format!(".snix-unpack-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        match std::fs::create_dir(&candidate) {
            Ok(()) => break candidate,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.into()),
        }
    };
    let result = (|| {
        let mut archive = tar::Archive::new(reader);
        archive.set_preserve_mtime(false);
        // tar's unpack implementation rejects traversal and refuses to follow
        // archive-created symlinks while creating subsequent entries.
        archive.unpack(&staging)?;
        let entries = std::fs::read_dir(&staging)?.collect::<Result<Vec<_>, _>>()?;
        // Nix strips a single directory wrapper, not an arbitrary first component.
        let source = if entries.len() == 1 && entries[0].file_type()?.is_dir() {
            entries[0].path()
        } else {
            staging.clone()
        };
        std::fs::rename(source, out)?;
        Ok(())
    })();
    if staging.exists() {
        let _ = std::fs::remove_dir_all(&staging);
    }
    result
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_url_decodes_local_paths() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("with space");
        let output = temp.path().join("download");
        std::fs::write(&input, b"local input").unwrap();
        let url = format!("file://{}", input.to_str().unwrap().replace(' ', "%20"));
        fetch_flat(&url, output.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read(output).unwrap(), b"local input");
        assert!(open_url("file://remote.example/etc/passwd").is_err());
    }

    #[test]
    fn unpack_preserves_multiple_top_level_entries() {
        let temp = tempfile::tempdir().unwrap();
        let mut builder = tar::Builder::new(Vec::new());
        for name in ["first", "second"] {
            let mut header = tar::Header::new_gnu();
            header.set_size(1);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, name, &b"x"[..]).unwrap();
        }
        let output = temp.path().join("out");
        extract_tar(std::io::Cursor::new(builder.into_inner().unwrap()), output.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read(output.join("first")).unwrap(), b"x");
        assert_eq!(std::fs::read(output.join("second")).unwrap(), b"x");
    }

    #[test]
    fn unpack_rejects_archive_symlink_parent_escape() {
        let temp = tempfile::tempdir().unwrap();
        let outside = temp.path().join("outside");
        std::fs::create_dir(&outside).unwrap();
        let mut builder = tar::Builder::new(Vec::new());
        let mut link = tar::Header::new_gnu();
        link.set_entry_type(tar::EntryType::Symlink);
        link.set_size(0);
        link.set_mode(0o777);
        link.set_link_name(&outside).unwrap();
        link.set_cksum();
        builder.append_data(&mut link, "wrapper/link", std::io::empty()).unwrap();
        let mut file = tar::Header::new_gnu();
        file.set_mode(0o644);
        file.set_size(4);
        file.set_cksum();
        builder.append_data(&mut file, "wrapper/link/escaped", &b"oops"[..]).unwrap();
        let output = temp.path().join("out");
        assert!(extract_tar(std::io::Cursor::new(builder.into_inner().unwrap()), output.to_str().unwrap()).is_err());
        assert!(!outside.join("escaped").exists());
        assert!(!output.exists());
    }

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
        builder.append_dir_all("project-v1", &inner_dir).unwrap();
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

    // ── fetchGit tests ───────────────────────────────────────────────

    #[test]
    fn fetch_git_from_local_repo() {

        let tmp = tempfile::tempdir().unwrap();
        let repo_dir = tmp.path().join("test-repo");
        std::fs::create_dir(&repo_dir).unwrap();

        // Create a git repo with one commit
        let run_git = |args: &[&str], dir: &std::path::Path| {
            std::process::Command::new(find_git().unwrap())
                .args(args)
                .current_dir(dir)
                .env("GIT_AUTHOR_NAME", "test")
                .env("GIT_AUTHOR_EMAIL", "test@test")
                .env("GIT_COMMITTER_NAME", "test")
                .env("GIT_COMMITTER_EMAIL", "test@test")
                .output()
                .expect("git command failed")
        };

        run_git(&["init"], &repo_dir);
        std::fs::write(repo_dir.join("hello.txt"), "hello from git").unwrap();
        run_git(&["add", "."], &repo_dir);
        run_git(&["commit", "-m", "initial"], &repo_dir);

        // Get the commit hash
        let rev_output = run_git(&["rev-parse", "HEAD"], &repo_dir);
        let rev = String::from_utf8(rev_output.stdout)
            .unwrap()
            .trim()
            .to_string();

        // Fetch via file:// URL
        let out_dir = tmp.path().join("output");
        let url = format!("file://{}", repo_dir.display());
        fetch_git(&url, &rev, out_dir.to_str().unwrap(), None).unwrap();

        // Verify output
        assert!(out_dir.join("hello.txt").exists());
        assert_eq!(
            std::fs::read_to_string(out_dir.join("hello.txt")).unwrap(),
            "hello from git"
        );
        // .git should NOT be in the output
        assert!(!out_dir.join(".git").exists());
    }

    #[test]
    fn fetch_git_cached_skips_clone() {
        let tmp = tempfile::tempdir().unwrap();
        let out_dir = tmp.path().join("already-exists");
        std::fs::create_dir(&out_dir).unwrap();
        std::fs::write(out_dir.join("marker"), "cached").unwrap();

        // Should succeed without actually cloning (path exists)
        let result = fetch_git(
            "https://example.com/nonexistent.git",
            "abc123",
            out_dir.to_str().unwrap(),
            None,
        );
        assert!(result.is_ok());
        // Original content preserved (not overwritten)
        assert_eq!(
            std::fs::read_to_string(out_dir.join("marker")).unwrap(),
            "cached"
        );
    }

}
