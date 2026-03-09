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

    // 3. Fetch from cache (extracts to /nix/store/)
    if !Path::new(&entry.store_path).exists() {
        eprintln!("installing {name} {}...", entry.version);
        fetch_and_extract(&entry.store_path, source)?;
    } else {
        eprintln!("'{name}' already in store, linking into profile...");
    }

    // 4. Add GC root to protect from garbage collection
    let root_name = format!("profile-{name}");
    store::add_root(&root_name, &entry.store_path)?;

    // 5. Discover binaries and create profile symlinks
    let binaries = link_package_binaries(&entry.store_path)?;

    if binaries.is_empty() {
        eprintln!("  note: no binaries found in {}/bin/", entry.store_path);
    } else {
        eprintln!("  linked {} binaries:", binaries.len());
        for bin in &binaries {
            eprintln!("    {bin}");
        }
    }

    // 6. Update profile manifest
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
        eprintln!("  binaries available in {PROFILE_BIN}/");
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

    // Remove profile symlinks
    for bin in &pkg.binaries {
        let link_path = PathBuf::from(PROFILE_BIN).join(bin);
        if link_path.is_symlink() {
            std::fs::remove_file(&link_path)?;
            eprintln!("  unlinked {bin}");
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

    println!("{} packages installed:", manifest.packages.len());
    println!();
    for (name, pkg) in &manifest.packages {
        println!("  {:<16} {:<12} ({} binaries)", name, pkg.version, pkg.binaries.len());
        for bin in &pkg.binaries {
            println!("    → {PROFILE_BIN}/{bin}");
        }
    }
    println!();
    println!("Profile: {PROFILE_DIR}");
    println!("Add {PROFILE_BIN} to PATH to use installed binaries.");

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

/// Fetch a store path from any cache source, decompress, verify hash, extract, and register.
fn fetch_and_extract(
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
    nar::extract(&mut buf_reader, &dest)?;

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

    store::register_path(&db, &dest, &nar_hash_hex, narinfo.nar_size, references, signatures)?;

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
}
