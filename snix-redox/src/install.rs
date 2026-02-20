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

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::local_cache;
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

/// Install a package by name from the local binary cache.
pub fn install(
    name: &str,
    cache_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Look up package in index
    let index = local_cache::read_index(cache_path)?;
    let entry = index
        .packages
        .get(name)
        .ok_or_else(|| format!("package '{name}' not found in cache. Run `snix search` to list available packages."))?;

    // 2. Check if already installed in profile
    let mut manifest = ProfileManifest::load();
    if manifest.packages.contains_key(name) {
        eprintln!("'{name}' is already installed in the current profile.");
        eprintln!("  store path: {}", entry.store_path);
        return Ok(());
    }

    // 3. Fetch from local cache (extracts to /nix/store/)
    if !Path::new(&entry.store_path).exists() {
        eprintln!("installing {name} {}...", entry.version);
        local_cache::fetch_local(&entry.store_path, cache_path)?;
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

/// Show detailed info about a package in the cache.
pub fn show(
    name: &str,
    cache_path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let index = local_cache::read_index(cache_path)?;
    let entry = index
        .packages
        .get(name)
        .ok_or_else(|| format!("package '{name}' not found in cache"))?;

    let manifest = ProfileManifest::load();
    let installed = manifest.packages.contains_key(name);
    let in_store = Path::new(&entry.store_path).exists();

    println!("Package: {name}");
    println!("  Name:       {}", entry.pname);
    println!("  Version:    {}", entry.version);
    println!("  Store path: {}", entry.store_path);
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
    println!("  Installed:  {}", if installed { "yes" } else { "no" });

    // Show binaries if installed
    if let Some(pkg) = manifest.packages.get(name) {
        if !pkg.binaries.is_empty() {
            println!("  Binaries:");
            for bin in &pkg.binaries {
                println!("    {bin}");
            }
        }
    } else if in_store {
        // Show what binaries would be available
        let bin_dir = PathBuf::from(&entry.store_path).join("bin");
        if bin_dir.is_dir() {
            let bins = list_binaries(&bin_dir)?;
            if !bins.is_empty() {
                println!("  Available binaries:");
                for bin in &bins {
                    println!("    {bin}");
                }
            }
        }
    }

    Ok(())
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
}
