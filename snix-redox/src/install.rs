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

/// Notify the stored daemon about a new store path's manifest.
///
/// Sends the manifest data (file list) so stored can serve directory
/// listings and file reads for packages installed after daemon startup.
fn stored_notify(store_path: &str, files: &[crate::nar::ManifestEntry]) {
    if files.is_empty() {
        return;
    }
    let cmd = serde_json::json!({
        "storePath": store_path,
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
        let _ = (store_path, cmd);
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
pub fn install(
    name: &str,
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
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
    let entry = index
        .packages
        .get(name)
        .ok_or_else(|| format!("package '{name}' not found in {}. Run `snix search` to list available packages.", source.display_name()))?;

    // 2. Check if already installed in profile
    let mut manifest = ProfileManifest::load();
    if manifest.packages.contains_key(name) {
        eprintln!("'{name}' is already installed in the current profile.");
        eprintln!("  store path: {}", entry.store_path);
        return Ok(());
    }

    // 3. Fetch from cache — eager or lazy
    let stored_running = stored_is_running();
    if lazy && stored_running {
        // Lazy install: register in PathInfoDb without extracting.
        // The stored daemon will extract on first access via the store: scheme.
        if !Path::new(&entry.store_path).exists() {
            eprintln!("lazy-installing {name} {} (stored will extract on demand)...", entry.version);
            register_without_extract(&entry.store_path, source)?;
        } else {
            eprintln!("'{name}' already in store...");
        }
    } else {
        if lazy && !stored_running {
            eprintln!("note: --lazy requires the stored daemon; falling back to eager install");
        }
        // Eager install: download, decompress, extract to /nix/store/
        if !Path::new(&entry.store_path).exists() {
            eprintln!("installing {name} {}...", entry.version);
            fetch_and_extract(&entry.store_path, source)?;
        } else {
            eprintln!("'{name}' already in store, linking into profile...");
        }
    }

    // 4. Notify stored daemon about the new manifest (if running).
    //    This lets stored serve directory listings and file content
    //    for packages installed after the daemon started.
    if stored_running {
        let files = crate::pathinfo::PathInfoDb::open()
            .ok()
            .and_then(|db| db.get(&entry.store_path).ok().flatten())
            .map(|info| info.files)
            .unwrap_or_default();
        stored_notify(&entry.store_path, &files);
    }

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
                list_binaries(&PathBuf::from(&entry.store_path).join("bin"))
                    .unwrap_or_default()
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

    let pkg = manifest
        .packages
        .remove(name)
        .ok_or_else(|| format!("'{name}' is not installed. Run `snix profile list` to see installed packages."))?;

    // Remove from profile — prefer profiled daemon, fall back to symlinks
    if profiled_is_running() {
        match profiled_remove(name) {
            Ok(()) => {
                eprintln!("  removed via profiled daemon");
            }
            Err(e) => {
                eprintln!("  warning: profiled command failed ({e}), falling back to symlink removal");
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
        println!("  {:<16} {:<12} ({} binaries)", name, pkg.version, pkg.binaries.len());
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
pub fn show(
    name: &str,
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
    // Delegate to the CacheSource's show_package which handles both variants
    source.show_package(name)
}

/// Install a package and all its transitive dependencies from a binary cache.
///
/// Uses BFS to discover dependencies from narinfo References fields.
/// Already-present local store paths are skipped.
pub fn install_recursive(
    name: &str,
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Look up package in index
    let index = source.read_index()?;
    let entry = index
        .packages
        .get(name)
        .ok_or_else(|| format!("package '{name}' not found in {}.", source.display_name()))?;

    // 2. BFS dependency resolution
    let mut queue: VecDeque<String> = VecDeque::new();
    let mut visited: BTreeSet<String> = BTreeSet::new();
    let mut fetched: u32 = 0;
    let mut skipped: u32 = 0;

    queue.push_back(entry.store_path.clone());

    let db = PathInfoDb::open()?;

    while let Some(path) = queue.pop_front() {
        if visited.contains(&path) {
            continue;
        }
        visited.insert(path.clone());

        let already_present = Path::new(&path).exists();
        let already_registered = db.is_registered(&path);

        if already_present && already_registered {
            skipped += 1;
            eprintln!("✓ already present: {path}");

            // Follow references for completeness
            if let Some(info) = db.get(&path)? {
                for r in &info.references {
                    if !visited.contains(r) {
                        queue.push_back(r.clone());
                    }
                }
            }
            continue;
        }

        // Fetch narinfo to discover references
        let sp = StorePath::<String>::from_absolute_path(path.as_bytes())?;
        let narinfo = source.fetch_narinfo(&sp)?;

        // Enqueue dependencies
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

        // Download and extract if not present
        if !already_present {
            fetch_and_extract(&path, source)?;
        } else if !already_registered {
            // Present on disk but not registered
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
        }

        fetched += 1;
    }

    eprintln!();
    eprintln!("Done: {fetched} fetched, {skipped} already present");

    // 3. Link into profile (same as regular install)
    let mut manifest = ProfileManifest::load();
    if !manifest.packages.contains_key(name) {
        let binaries = link_package_binaries(&entry.store_path)?;

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

        let root_name = format!("profile-{name}");
        store::add_root(&root_name, &entry.store_path)?;

        eprintln!("✓ installed {name} {} (with dependencies)", entry.version);
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
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
    let sp = StorePath::<String>::from_absolute_path(store_path_str.as_bytes())?;

    // Fetch narinfo for metadata
    let narinfo = source.fetch_narinfo(&sp)?;

    // Register in PathInfoDb (no extraction — stored daemon handles that)
    let db = PathInfoDb::open()?;
    let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
    let references: Vec<String> = narinfo
        .references
        .iter()
        .map(|r| r.to_absolute_path())
        .collect();
    let signatures: Vec<String> = narinfo.signatures.iter().map(|s| s.to_string()).collect();

    store::register_path(&db, store_path_str, &nar_hash_hex, narinfo.nar_size, references, signatures)?;

    eprintln!("✓ registered (lazy): {store_path_str}");
    Ok(())
}

/// Fetch a store path from any cache source, decompress, verify hash, extract, and register.
/// Extract a package from the binary cache to /nix/store/.
///
/// Fetches the narinfo, decompresses the NAR, extracts, verifies hash,
/// and registers in PathInfoDb. Skips if the store path already exists.
pub fn fetch_and_extract(
    store_path_str: &str,
    source: &CacheSource,
) -> Result<(), Box<dyn std::error::Error>> {
    let sp = StorePath::<String>::from_absolute_path(store_path_str.as_bytes())?;
    let dest = sp.to_absolute_path();

    if Path::new(&dest).exists() {
        eprintln!("already exists: {dest}");
        return Ok(());
    }

    store::ensure_store_dir()?;

    // Fetch narinfo
    eprintln!("fetching narinfo for {}...", sp.to_absolute_path());
    let narinfo = source.fetch_narinfo(&sp)?;

    // Open and decompress the NAR
    let decompressed = source.open_nar_decompressed(&narinfo)?;

    // Hash while extracting
    let mut hashing = HashingReader::new(decompressed);
    let mut buf_reader = BufReader::new(&mut hashing);

    eprintln!("extracting to {dest}...");
    let manifest = nar::extract_with_manifest(&mut buf_reader, &dest)?;

    // Verify hash
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

    // Register in PathInfoDb
    let db = PathInfoDb::open()?;
    let nar_hash_hex = data_encoding::HEXLOWER.encode(&narinfo.nar_hash);
    let references: Vec<String> = narinfo
        .references
        .iter()
        .map(|r| r.to_absolute_path())
        .collect();
    let signatures: Vec<String> = narinfo.signatures.iter().map(|s| s.to_string()).collect();

    store::register_path_with_files(
        &db, &dest, &nar_hash_hex, narinfo.nar_size,
        references, signatures, manifest,
    )?;

    eprintln!("✓ verified and installed: {dest}");
    Ok(())
}

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
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        if n > 0 {
            self.hasher.update(&buf[..n]);
        }
        Ok(n)
    }
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
    fn cache_source_from_args_url_priority() {
        // cache_url takes priority over cache_path
        let src = CacheSource::from_args(
            Some("http://10.0.2.2:8080"),
            Some("/nix/cache"),
        );
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
}
