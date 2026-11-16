//! Package installation, removal, and profile management.
//!
//! Profiles are directories of symlinks pointing into /nix/store/.
//! Each profile tracks which packages are installed via a manifest.
//!
//! Layout:
//!   /nix/var/snix/profiles/default/
//!     bin/           — symlinks to package binaries
//!     manifest.json  — installed package metadata
//!
//! Commands:
//!   snix install <name>   — fetch from cache, extract, link into profile
//!   snix remove <name>    — unlink from profile, remove GC root
//!   snix profile list     — show installed packages

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};

use nix_compat::narinfo::NarInfo;
use nix_compat::store_path::StorePath;
use sha2::{Digest, Sha256};

use crate::cache_source::CacheSource;
use crate::local_cache;
use crate::nar;
use crate::pathinfo::PathInfoDb;
use crate::store;

// ─── Profiled Scheme Integration ───────────────────────────────────────────

/// Check if the `profiled` daemon is running by trying to access its control file.
///
/// On Redox: attempts to open `profile:default/.control`.
/// On other platforms: always returns false (no scheme support).
fn profiled_is_running() -> bool {
    #[cfg(target_os = "redox")]
    {
        // Try to access the profiled scheme. If it's running, the file exists.
        std::fs::metadata("profile:default/.control").is_ok()
    }
    #[cfg(not(target_os = "redox"))]
    {
        false
    }
}

/// Send an "add" command to the profiled daemon.
///
/// Writes a JSON command to `profile:default/.control`.
/// Returns Ok(()) on success, Err if the write fails.
fn profiled_add(name: &str, store_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    // Load the manifest from PathInfo to send to profiled.
    let files = crate::pathinfo::PathInfoDb::open()
        .ok()
        .and_then(|db| db.get(store_path).ok().flatten())
        .map(|info| info.files)
        .unwrap_or_default();

    let cmd = serde_json::json!({
        "action": "add",
        "name": name,
        "storePath": store_path,
        "files": files
    });
    #[cfg(target_os = "redox")]
    {
        std::fs::write("profile:default/.control", cmd.to_string())?;
    }
    #[cfg(not(target_os = "redox"))]
    {
        let _ = (name, store_path, cmd);
        return Err("profiled not available on this platform".into());
    }
    Ok(())
}

/// Send a "remove" command to the profiled daemon.
fn profiled_remove(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let cmd = serde_json::json!({
        "action": "remove",
        "name": name
    });
    #[cfg(target_os = "redox")]
    {
        std::fs::write("profile:default/.control", cmd.to_string())?;
    }
    #[cfg(not(target_os = "redox"))]
    {
        let _ = (name, cmd);
        return Err("profiled not available on this platform".into());
    }
    Ok(())
}

/// Notify the stored daemon about a new or updated store path.
///
/// Sends enough metadata for `stored` to remember the path even when the
/// package was lazy-installed and has no file manifest yet.
fn stored_notify(store_path: &str, nar_hash: &str, files: &[crate::nar::ManifestEntry]) {
    let cmd = serde_json::json!({
        "storePath": store_path,
        "narHash": nar_hash,
        "files": files
    });
    #[cfg(target_os = "redox")]
    {
        if let Err(e) = std::fs::write("store:.control", cmd.to_string()) {
            eprintln!("  note: stored notification failed ({e}), will use filesystem fallback");
        }
    }
    #[cfg(not(target_os = "redox"))]
    {
        let _ = (store_path, nar_hash, cmd);
    }
}

/// Check if the `stored` daemon is running.
///
/// On Redox: attempts to access the `store:` scheme root.
/// On other platforms: always returns false.
fn stored_is_running() -> bool {
    #[cfg(target_os = "redox")]
    {
        std::fs::metadata("store:").is_ok()
    }
    #[cfg(not(target_os = "redox"))]
    {
        false
    }
}

/// Read the package list from profiled daemon (via `.control` with list command).
///
/// Returns None if profiled is not running.
fn profiled_list() -> Option<Vec<(String, String)>> {
    #[cfg(target_os = "redox")]
    {
        let cmd = serde_json::json!({"action": "list"});
        if std::fs::write("profile:default/.control", cmd.to_string()).is_ok() {
            // Read response — profiled writes the result back on the control fd.
            // For now, fall back to manifest-based listing since the scheme
            // protocol is request/response on separate fds.
            None
        } else {
            None
        }
    }
    #[cfg(not(target_os = "redox"))]
    {
        None
    }
}

/// Default profile directory.
const PROFILE_DIR: &str = "/nix/var/snix/profiles/default";
const PROFILE_BIN: &str = "/nix/var/snix/profiles/default/bin";
const PROFILE_MANIFEST: &str = "/nix/var/snix/profiles/default/manifest.json";

/// Installed package record in the profile manifest.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledPackage {
    pub name: String,
    pub pname: String,
    pub version: String,
    pub store_path: String,
    pub binaries: Vec<String>,
}

/// Profile manifest.
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct ProfileManifest {
    pub version: u32,
    pub packages: BTreeMap<String, InstalledPackage>,
}

impl ProfileManifest {
    fn load() -> Self {
        match std::fs::read_to_string(PROFILE_MANIFEST) {
            Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
            Err(_) => Self {
                version: 1,
                ..Default::default()
            },
        }
    }

    fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        ensure_dir(PROFILE_DIR)?;
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(PROFILE_MANIFEST, json)?;
        Ok(())
    }
}

/// Install a package by name from a binary cache (local or remote).
pub fn install(name: &str, source: &CacheSource) -> Result<(), Box<dyn std::error::Error>> {
    install_with_options(name, source, false)
}

/// Install a package with optional lazy mode.
///
/// When `lazy` is true and `stored` daemon is running, the package is
/// registered in PathInfoDb and the profile mapping without extracting
/// the NAR. The `stored` daemon will extract on first access.
/// When `lazy` is true but `stored` is not running, falls back to eager
/// extraction (lazy requires stored for on-demand access).
pub fn install_with_options(
    name: &str,
    source: &CacheSource,
    lazy: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Look up package in index
    let index = source.read_index()?;
    let entry = index.packages.get(name).ok_or_else(|| {
        format!(
            "package '{name}' not found in {}. Run `snix search` to list available packages.",
            source.display_name()
        )
    })?;

    // 2. Check if already installed in profile
    let mut manifest = ProfileManifest::load();
    if manifest.packages.contains_key(name) {
        eprintln!("'{name}' is already installed in the current profile.");
        eprintln!("  store path: {}", entry.store_path);
        return Ok(());
    }

    // Every install traverses narinfo references, including local/offline and
    // lazy installs. A root-only install is not valid for a version-2 catalog.
    // Resolve the whole graph before changing the store or the profile.
    let stored_running = stored_is_running();
    if lazy && !stored_running {
        eprintln!("note: --lazy requires the stored daemon; falling back to eager install");
    }
    fetch_closure_with_mode(&entry.store_path, source, lazy && stored_running)?;

    // 5. Add GC root to protect from garbage collection
    let root_name = format!("profile-{name}");
    store::add_root(&root_name, &entry.store_path)?;

    // 5. Link into profile — prefer profiled daemon, fall back to symlinks
    let binaries = if profiled_is_running() {
        // Use the profiled scheme daemon (no symlinks needed).
        match profiled_add(name, &entry.store_path) {
            Ok(()) => {
                eprintln!("  registered via profiled daemon");
                // Discover binaries for manifest metadata (informational only).
                list_binaries(&PathBuf::from(&entry.store_path).join("bin")).unwrap_or_default()
            }
            Err(e) => {
                eprintln!("  warning: profiled command failed ({e}), falling back to symlinks");
                link_package_binaries(&entry.store_path)?
            }
        }
    } else {
        // Fall back to traditional symlink-based profile.
        link_package_binaries(&entry.store_path)?
    };

    if binaries.is_empty() {
        eprintln!("  note: no binaries found in {}/bin/", entry.store_path);
    } else {
        eprintln!("  linked {} binaries:", binaries.len());
        for bin in &binaries {
            eprintln!("    {bin}");
        }
    }

    // 6. Update profile manifest (always, regardless of profiled/symlink mode)
    manifest.packages.insert(
        name.to_string(),
        InstalledPackage {
            name: name.to_string(),
            pname: entry.pname.clone(),
            version: entry.version.clone(),
            store_path: entry.store_path.clone(),
            binaries: binaries.clone(),
        },
    );
    manifest.save()?;

    eprintln!();
    eprintln!("✓ installed {name} {}", entry.version);
    if !binaries.is_empty() {
        if profiled_is_running() {
            eprintln!("  binaries available via profile: scheme");
        } else {
            eprintln!("  binaries available in {PROFILE_BIN}/");
        }
    }

    Ok(())
}

/// Remove a package from the profile.
pub fn remove(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut manifest = ProfileManifest::load();

    let pkg = manifest.packages.remove(name).ok_or_else(|| {
        format!("'{name}' is not installed. Run `snix profile list` to see installed packages.")
    })?;

    // Remove from profile — prefer profiled daemon, fall back to symlinks
    if profiled_is_running() {
        match profiled_remove(name) {
            Ok(()) => {
                eprintln!("  removed via profiled daemon");
            }
            Err(e) => {
                eprintln!(
                    "  warning: profiled command failed ({e}), falling back to symlink removal"
                );
                for bin in &pkg.binaries {
                    let link_path = PathBuf::from(PROFILE_BIN).join(bin);
                    if link_path.is_symlink() {
                        std::fs::remove_file(&link_path)?;
                        eprintln!("  unlinked {bin}");
                    }
                }
            }
        }
    } else {
        // Traditional symlink removal
        for bin in &pkg.binaries {
            let link_path = PathBuf::from(PROFILE_BIN).join(bin);
            if link_path.is_symlink() {
                std::fs::remove_file(&link_path)?;
                eprintln!("  unlinked {bin}");
            }
        }
    }

    // Remove GC root
    let root_name = format!("profile-{name}");
    let _ = store::remove_root(&root_name); // Best-effort

    manifest.save()?;

    eprintln!("✓ removed {name}");
    eprintln!("  store path still exists: {}", pkg.store_path);
    eprintln!("  run `snix store gc` to reclaim space");

    Ok(())
}

/// List installed packages in the profile.
pub fn list_profile() -> Result<(), Box<dyn std::error::Error>> {
    let manifest = ProfileManifest::load();

    if manifest.packages.is_empty() {
        println!("No packages installed in profile.");
        println!("Use `snix install <package>` to install from the local cache.");
        return Ok(());
    }

    let using_profiled = profiled_is_running();

    println!("{} packages installed:", manifest.packages.len());
    if using_profiled {
        println!("  (profiled daemon active — union view via profile: scheme)");
    }
    println!();
    for (name, pkg) in &manifest.packages {
        println!(
            "  {:<16} {:<12} ({} binaries)",
            name,
            pkg.version,
            pkg.binaries.len()
        );
        for bin in &pkg.binaries {
            if using_profiled {
                println!("    → profile:default/bin/{bin}");
            } else {
                println!("    → {PROFILE_BIN}/{bin}");
            }
        }
    }
    println!();
    if using_profiled {
        println!("Profile: profile:default/ (via profiled daemon)");
    } else {
        println!("Profile: {PROFILE_DIR}");
        println!("Add {PROFILE_BIN} to PATH to use installed binaries.");
    }

    Ok(())
}

/// Show detailed info about a package in the cache (local or remote).
pub fn show(name: &str, source: &CacheSource) -> Result<(), Box<dyn std::error::Error>> {
    // Delegate to the CacheSource's show_package which handles both variants
    source.show_package(name)
}

/// Explicit recursive CLI mode, retained for version-1 catalog workflows.
/// All installs now traverse references; both entry points share profile logic.
pub fn install_recursive(
    name: &str,
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
    install(name, source)
}

/// Discover a closure from authoritative narinfos, including paths already on
/// disk. Do not trust an old local registration to hide a missing dependency.
fn resolve_closure(
    root: &str,
    source: &CacheSource,
) -> Result<Vec<(String, NarInfo<'static>)>, Box<dyn std::error::Error>> {
    let mut queue = VecDeque::from([root.to_string()]);
    let mut visited = BTreeSet::new();
    let mut paths = Vec::new();
    while let Some(path) = queue.pop_front() {
        if !visited.insert(path.clone()) {
            continue;
        }
        let sp = StorePath::<String>::from_absolute_path(path.as_bytes())?;
        let narinfo = source.fetch_narinfo(&sp)
            .map_err(|error| format!("cannot resolve closure member {path}: {error}"))?;
        for reference in &narinfo.references {
            let reference = reference.to_absolute_path();
            if !visited.contains(&reference) {
                queue.push_back(reference);
            }
        }
        paths.push((path, narinfo));
    }
    Ok(paths)
}

fn fetch_closure_with_mode(
    root: &str,
    source: &CacheSource,
    lazy: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let paths = resolve_closure(root, source)?;
    let db = PathInfoDb::open()?;
    store::ensure_store_dir()?;
    let stored_running = stored_is_running();
    for (path, narinfo) in paths {
        let present = Path::new(&path).symlink_metadata().is_ok();
        if lazy || present {
            if !present || !db.is_registered(&path) {
                register_without_extract(&path, &narinfo, &db)?;
            }
        } else {
            extract_narinfo(&path, &narinfo, source, &db)
                .map_err(|error| format!("cannot restore closure member {path}: {error}"))?;
        }
        if stored_running {
            if let Some(info) = db.get(&path)? {
                stored_notify(&path, &info.nar_hash, &info.files);
            }
        }
    }
    Ok(())
}

// ─── Fetch & Extract ───────────────────────────────────────────────────────

/// Register a store path in PathInfoDb WITHOUT extracting the NAR.
///
/// Used for lazy installs when the stored daemon will handle extraction
/// on first access. Fetches only the narinfo (small metadata file) to
/// get the hash, size, and references for registration.
fn register_without_extract(
    store_path_str: &str,
    narinfo: &NarInfo<'_>,
    db: &PathInfoDb,
) -> Result<(), Box<dyn std::error::Error>> {
    let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
    let references: Vec<String> = narinfo
        .references
        .iter()
        .map(|r| r.to_absolute_path())
        .collect();
    let signatures: Vec<String> = narinfo.signatures.iter().map(|s| s.to_string()).collect();

    store::register_path(
        db,
        store_path_str,
        &nar_hash_hex,
        narinfo.nar_size,
        references,
        signatures,
    )?;

    eprintln!("✓ registered (lazy): {store_path_str}");
    Ok(())
}

/// Restore a complete reference closure without creating a profile entry.
/// Every new payload is decompressed, NAR-verified, atomically published, and
/// registered; existing payloads are retained while their references are followed.
pub fn fetch_and_extract(
    store_path_str: &str,
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
    fetch_closure_with_mode(store_path_str, source, false)
}

fn extract_narinfo(
    dest: &str,
    narinfo: &NarInfo<'_>,
    source: &CacheSource,
    db: &PathInfoDb,
) -> Result<(), Box<dyn std::error::Error>> {
    let decompressed = source.open_nar_decompressed(narinfo)?;
    eprintln!("extracting to {dest}...");
    let manifest = extract_verified(
        decompressed, Path::new(dest), &narinfo.nar_hash, narinfo.nar_size,
    )?;

    // Publish metadata only after the verified payload is atomically in place.
    let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
    let references: Vec<String> = narinfo
        .references
        .iter()
        .map(|r| r.to_absolute_path())
        .collect();
    let signatures: Vec<String> = narinfo.signatures.iter().map(|s| s.to_string()).collect();

    store::register_path_with_files(
        db,
        dest,
        &nar_hash_hex,
        narinfo.nar_size,
        references,
        signatures,
        manifest,
    )?;

    eprintln!("✓ verified and installed: {dest}");
    Ok(())
}

/// Extract into a private sibling directory; only verified NARs become store
/// paths. The guard removes every partial file on parsing/hash/rename failure.
struct ExtractionStage {
    directory: PathBuf,
}

impl ExtractionStage {
    fn new(parent: &Path) -> Result<Self, std::io::Error> {
        use std::os::unix::fs::DirBuilderExt;
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT_STAGE: AtomicU64 = AtomicU64::new(0);
        loop {
            let id = NEXT_STAGE.fetch_add(1, Ordering::Relaxed);
            let directory = parent.join(format!(".snix-extract-{}-{id}", std::process::id()));
            match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
                Ok(()) => return Ok(Self { directory }),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for ExtractionStage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn extract_verified(
    reader: Box<dyn Read + Send>,
    destination: &Path,
    expected_hash: &[u8; 32],
    expected_size: u64,
) -> Result<Vec<nar::ManifestEntry>, Box<dyn std::error::Error>> {
    let parent = destination.parent().ok_or("store path has no parent")?;
    let stage = ExtractionStage::new(parent)?;
    let payload = stage.directory.join("payload");
    let mut hashing = HashingReader::new(reader);
    let manifest = {
        let mut buffered = BufReader::new(&mut hashing);
        let manifest = nar::extract_with_manifest(
            &mut buffered,
            payload.to_str().ok_or("non-UTF8 staging path")?,
        )?;
        if buffered.read(&mut [0_u8; 1])? != 0 {
            return Err("trailing data after NAR archive".into());
        }
        manifest
    };
    if hashing.bytes_read != expected_size {
        return Err(format!("NAR size mismatch: expected {expected_size}, got {}", hashing.bytes_read).into());
    }
    verify_nar_hash(expected_hash, &hashing.finalize())?;
    if destination.symlink_metadata().is_ok() {
        return Err(format!("store path appeared during extraction: {}", destination.display()).into());
    }
    std::fs::rename(&payload, destination)?;
    Ok(manifest)
}

/// Reader wrapper that hashes content as it's read.
struct HashingReader<R> {
    inner: R,
    hasher: Sha256,
    bytes_read: u64,
}

impl<R: Read> HashingReader<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
            bytes_read: 0,
        }
    }

    fn finalize(self) -> [u8; 32] {
        self.hasher.finalize().into()
    }
}

impl<R: Read> Read for HashingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        if n > 0 {
            self.hasher.update(&buf[..n]);
            self.bytes_read += n as u64;
        }
        Ok(n)
    }
}

fn verify_nar_hash(
    expected: &[u8; 32],
    actual: &[u8; 32],
) -> Result<(), Box<dyn std::error::Error>> {
    if actual == expected {
        return Ok(());
    }

    Err(format!(
        "NAR hash mismatch!\n  expected: {}\n  got:      {}",
        data_encoding::HEXLOWER.encode(expected),
        data_encoding::HEXLOWER.encode(actual),
    )
    .into())
}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Discover binaries in a store path and create profile symlinks.
fn link_package_binaries(store_path: &str) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    ensure_dir(PROFILE_BIN)?;

    let bin_dir = PathBuf::from(store_path).join("bin");
    if !bin_dir.is_dir() {
        return Ok(vec![]);
    }

    let mut binaries = Vec::new();

    for entry in std::fs::read_dir(&bin_dir)? {
        let entry = entry?;
        let file_name = entry.file_name();
        let name = file_name.to_string_lossy().to_string();

        let target = entry.path();
        let link = PathBuf::from(PROFILE_BIN).join(&name);

        // Remove existing symlink if present (might be from different version)
        if link.is_symlink() {
            std::fs::remove_file(&link)?;
        }

        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link)?;

        #[cfg(not(unix))]
        std::fs::copy(&target, &link)?;

        binaries.push(name);
    }

    binaries.sort();
    Ok(binaries)
}

fn list_binaries(bin_dir: &Path) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let mut bins = Vec::new();
    if bin_dir.is_dir() {
        for entry in std::fs::read_dir(bin_dir)? {
            let entry = entry?;
            bins.push(entry.file_name().to_string_lossy().to_string());
        }
    }
    bins.sort();
    Ok(bins)
}

fn ensure_dir(path: &str) -> Result<(), std::io::Error> {
    std::fs::create_dir_all(path)
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
    fn profile_manifest_roundtrip() {
        let mut manifest = ProfileManifest {
            version: 1,
            packages: BTreeMap::new(),
        };

        manifest.packages.insert(
            "ripgrep".to_string(),
            InstalledPackage {
                name: "ripgrep".to_string(),
                pname: "ripgrep".to_string(),
                version: "14.1.0".to_string(),
                store_path: "/nix/store/abc-ripgrep-14.1.0".to_string(),
                binaries: vec!["rg".to_string()],
            },
        );

        let json = serde_json::to_string_pretty(&manifest).unwrap();
        let parsed: ProfileManifest = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.packages.len(), 1);
        assert_eq!(parsed.packages["ripgrep"].binaries, vec!["rg"]);
    }

    #[test]
    fn empty_profile_manifest() {
        let manifest = ProfileManifest::default();
        assert_eq!(manifest.version, 0);
        assert!(manifest.packages.is_empty());
    }

    #[test]
    fn installed_package_serialization() {
        let pkg = InstalledPackage {
            name: "test".to_string(),
            pname: "test-pkg".to_string(),
            version: "1.0".to_string(),
            store_path: "/nix/store/abc-test-1.0".to_string(),
            binaries: vec!["bin1".to_string(), "bin2".to_string()],
        };

        let json = serde_json::to_string(&pkg).unwrap();
        assert!(json.contains("storePath"));
        assert!(json.contains("test-pkg"));
    }

    #[test]
    fn hashing_reader_verifies_content() {
        use std::io::Cursor;

        let data = b"hello world of nix binary caches";
        let expected_hash = Sha256::digest(data);

        let cursor = Cursor::new(data.to_vec());
        let mut reader = HashingReader::new(cursor);

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

        let actual_hash = reader.finalize();
        assert_eq!(actual_hash, expected_hash.as_slice());
    }

    #[test]
    fn hashing_reader_incremental_reads() {
        use std::io::Cursor;

        let data = b"abcdefghijklmnop";
        let expected = Sha256::digest(data);

        let cursor = Cursor::new(data.to_vec());
        let mut reader = HashingReader::new(cursor);

        // Read in 4-byte chunks
        let mut buf = [0u8; 4];
        for _ in 0..4 {
            let n = reader.read(&mut buf).unwrap();
            assert_eq!(n, 4);
        }

        assert_eq!(reader.finalize(), expected.as_slice());
    }

    #[test]
    fn verify_nar_hash_accepts_match() {
        let hash = Sha256::digest(b"nar");
        let mut expected = [0_u8; 32];
        expected.copy_from_slice(&hash);
        assert!(verify_nar_hash(&expected, &expected).is_ok());
    }

    #[test]
    fn verify_nar_hash_rejects_mismatch() {
        let expected_digest = Sha256::digest(b"expected");
        let actual_digest = Sha256::digest(b"actual");
        let mut expected = [0_u8; 32];
        let mut actual = [0_u8; 32];
        expected.copy_from_slice(&expected_digest);
        actual.copy_from_slice(&actual_digest);

        let err = verify_nar_hash(&expected, &actual).unwrap_err().to_string();
        assert!(err.contains("NAR hash mismatch"));
        assert!(err.contains(&data_encoding::HEXLOWER.encode(&expected)));
        assert!(err.contains(&data_encoding::HEXLOWER.encode(&actual)));
    }

    #[test]
    fn cache_source_from_args_url_priority() {
        // cache_url takes priority over cache_path
        let src = CacheSource::from_args(Some("http://10.0.2.2:8080"), Some("/nix/cache"));
        assert!(src.is_remote());
    }

    #[test]
    fn cache_source_from_args_path_fallback() {
        let src = CacheSource::from_args(None, Some("/my/cache"));
        assert!(src.is_local());
    }

    // ── Scheme Integration Tests ───────────────────────────────────────

    #[test]
    fn profiled_not_running_on_linux() {
        // On Linux, profiled_is_running() always returns false
        // (no scheme support outside Redox).
        assert!(!profiled_is_running());
    }

    #[test]
    fn stored_not_running_on_linux() {
        // On Linux, stored_is_running() always returns false.
        assert!(!stored_is_running());
    }

    #[test]
    fn profiled_add_fails_on_linux() {
        // On non-Redox, profiled_add returns an error.
        let result = profiled_add("test", "/nix/store/abc-test-1.0");
        assert!(result.is_err());
    }

    #[test]
    fn profiled_remove_fails_on_linux() {
        // On non-Redox, profiled_remove returns an error.
        let result = profiled_remove("test");
        assert!(result.is_err());
    }

    #[test]
    fn profiled_list_none_on_linux() {
        // On non-Redox, profiled_list returns None.
        assert!(profiled_list().is_none());
    }

    const CLOSURE_A: &str = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
    const CLOSURE_B: &str = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b";
    const CLOSURE_C: &str = "/nix/store/cccccccccccccccccccccccccccccccc-c";
    const CLOSURE_D: &str = "/nix/store/dddddddddddddddddddddddddddddddd-d";

    fn closure_cache(edges: &[(&str, &[&str])]) -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        for (path, references) in edges {
            let basename = Path::new(path).file_name().unwrap().to_str().unwrap();
            let references = references.iter()
                .map(|reference| Path::new(reference).file_name().unwrap().to_str().unwrap())
                .collect::<Vec<_>>().join(" ");
            let narinfo = format!(
                "StorePath: {path}\nURL: nar/{basename}.nar\nCompression: none\nNarHash: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nNarSize: 0\nReferences: {references}\n"
            );
            std::fs::write(directory.path().join(format!("{}.narinfo", &basename[..32])), narinfo).unwrap();
        }
        directory
    }

    fn resolved_paths(root: &str, source: &CacheSource) -> Result<Vec<String>, Box<dyn std::error::Error>> {
        Ok(resolve_closure(root, source)?.into_iter().map(|(path, _)| path).collect())
    }

    #[test]
    fn recursive_resolution_follows_chain_and_reports_missing_dependency() {
        let cache = closure_cache(&[(CLOSURE_A, &[CLOSURE_B]), (CLOSURE_B, &[CLOSURE_C]), (CLOSURE_C, &[])]);
        let source = CacheSource::Local(cache.path().to_path_buf());
        assert_eq!(resolved_paths(CLOSURE_A, &source).unwrap(), [CLOSURE_A, CLOSURE_B, CLOSURE_C]);
        std::fs::remove_file(cache.path().join(format!("{}.narinfo", "c".repeat(32)))).unwrap();
        let error = resolve_closure(CLOSURE_A, &source).unwrap_err().to_string();
        assert!(error.contains("cannot resolve closure member"));
        assert!(error.contains(CLOSURE_C));
    }

    #[test]
    fn recursive_resolution_terminates_for_diamond_and_self_reference() {
        let cache = closure_cache(&[
            (CLOSURE_A, &[CLOSURE_A, CLOSURE_B, CLOSURE_C]),
            (CLOSURE_B, &[CLOSURE_D]), (CLOSURE_C, &[CLOSURE_D]), (CLOSURE_D, &[]),
        ]);
        let source = CacheSource::Local(cache.path().to_path_buf());
        assert_eq!(resolved_paths(CLOSURE_A, &source).unwrap(), [CLOSURE_A, CLOSURE_B, CLOSURE_C, CLOSURE_D]);
    }

    #[test]
    fn missing_dependency_payload_is_explicit() {
        let cache = closure_cache(&[(CLOSURE_A, &[CLOSURE_B]), (CLOSURE_B, &[])]);
        let source = CacheSource::Local(cache.path().to_path_buf());
        resolved_paths(CLOSURE_A, &source).unwrap();
        let sp = StorePath::<String>::from_absolute_path(CLOSURE_B.as_bytes()).unwrap();
        let narinfo = source.fetch_narinfo(&sp).unwrap();
        let error = source.open_nar(&narinfo).err().unwrap().to_string();
        assert!(error.contains("NAR file not found"));
        assert!(error.contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b.nar"));
    }

    #[test]
    fn extraction_only_publishes_verified_complete_nar() {
        let bytes = include_bytes!("../testdata/nar/helloworld.nar");
        let hash: [u8; 32] = Sha256::digest(bytes).into();
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().join("payload");
        extract_verified(Box::new(std::io::Cursor::new(bytes.to_vec())), &destination, &hash, bytes.len() as u64).unwrap();
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "Hello World!");
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn failed_extraction_hash_size_and_parse_leave_no_store_path() {
        let bytes = include_bytes!("../testdata/nar/helloworld.nar");
        let hash: [u8; 32] = Sha256::digest(bytes).into();
        for (input, expected_hash, expected_size) in [
            (bytes.to_vec(), [0_u8; 32], bytes.len() as u64),
            (bytes.to_vec(), hash, bytes.len() as u64 + 1),
            (bytes[..bytes.len() / 2].to_vec(), hash, bytes.len() as u64),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let destination = directory.path().join("payload");
            assert!(extract_verified(Box::new(std::io::Cursor::new(input)), &destination, &expected_hash, expected_size).is_err());
            assert!(destination.symlink_metadata().is_err());
            assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
        }
    }
}
