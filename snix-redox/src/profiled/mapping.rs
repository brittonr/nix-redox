//! Profile mapping table — the core data structure for `profiled`.
//!
//! Each profile is a named list of installed packages. The mapping is
//! persisted to JSON and loaded on daemon startup. All mutations are
//! atomic (write-to-temp + rename).
//!
//! Layout:
//! ```text
//! /nix/var/snix/profiles/
//!   default/
//!     mapping.json     — serialized ProfileMapping
//!   dev/
//!     mapping.json
//! ```

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// A single installed package in a profile.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileEntry {
    /// Package name (e.g., "ripgrep").
    pub name: String,
    /// Absolute store path (e.g., "/nix/store/abc...-ripgrep-14.1.0").
    pub store_path: String,
    /// Unix timestamp when the package was installed.
    pub installed_at: u64,
}

/// The mapping for a single profile.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProfileMapping {
    /// Schema version.
    pub version: u32,
    /// Installed packages in installation order.
    pub packages: Vec<ProfileEntry>,
}

impl ProfileMapping {
    /// Add a package to the profile. If already present, replaces it.
    pub fn add(&mut self, name: &str, store_path: &str) {
        // Remove existing entry with the same name.
        self.packages.retain(|p| p.name != name);

        self.packages.push(ProfileEntry {
            name: name.to_string(),
            store_path: store_path.to_string(),
            installed_at: current_timestamp(),
        });
    }

    /// Remove a package by name. Returns true if it was found.
    pub fn remove(&mut self, name: &str) -> bool {
        let before = self.packages.len();
        self.packages.retain(|p| p.name != name);
        self.packages.len() < before
    }

    /// Look up a package by name.
    pub fn get(&self, name: &str) -> Option<&ProfileEntry> {
        self.packages.iter().find(|p| p.name == name)
    }

    /// Find which package provides a given subpath (e.g., `bin/rg`).
    ///
    /// Searches in reverse installation order (last installed wins).
    /// Checks the filesystem to verify the file actually exists.
    pub fn resolve_path(&self, subpath: &str) -> Option<ResolvedFile> {
        for entry in self.packages.iter().rev() {
            let full = PathBuf::from(&entry.store_path).join(subpath);
            if full.exists() {
                return Some(ResolvedFile {
                    package_name: entry.name.clone(),
                    store_path: entry.store_path.clone(),
                    full_path: full,
                });
            }
        }
        None
    }

    /// List all files at a given subpath across all packages (union view).
    ///
    /// Returns deduplicated entries (last-installed-wins for conflicts).
    pub fn list_union(&self, subpath: &str) -> Vec<UnionEntry> {
        let mut seen = BTreeMap::new();

        // Iterate in installation order so later installs overwrite earlier.
        for entry in &self.packages {
            let dir = PathBuf::from(&entry.store_path).join(subpath);
            if dir.is_dir() {
                if let Ok(read) = fs::read_dir(&dir) {
                    for dir_entry in read.flatten() {
                        let name = dir_entry.file_name().to_string_lossy().to_string();
                        let ft = dir_entry.file_type().unwrap_or_else(|_| {
                            // Fallback: treat as regular file.
                            dir_entry.file_type().unwrap()
                        });
                        seen.insert(
                            name.clone(),
                            UnionEntry {
                                name,
                                is_dir: ft.is_dir(),
                                is_symlink: ft.is_symlink(),
                                from_package: entry.name.clone(),
                            },
                        );
                    }
                }
            }
        }

        let mut entries: Vec<UnionEntry> = seen.into_values().collect();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        entries
    }
}

/// A file resolved through the profile mapping.
#[derive(Debug, Clone)]
pub struct ResolvedFile {
    /// Which package provided the file.
    pub package_name: String,
    /// The package's store path.
    pub store_path: String,
    /// Absolute path to the file on disk.
    pub full_path: PathBuf,
}

/// An entry in a union directory listing.
#[derive(Debug, Clone)]
pub struct UnionEntry {
    /// Filename.
    pub name: String,
    /// Whether it's a directory.
    pub is_dir: bool,
    /// Whether it's a symlink.
    pub is_symlink: bool,
    /// Which package provides this entry.
    pub from_package: String,
}

/// All profiles managed by the daemon.
pub struct ProfileStore {
    /// Profile name → mapping.
    profiles: BTreeMap<String, ProfileMapping>,
    /// Base directory for persistence.
    profiles_dir: String,
}

impl ProfileStore {
    /// Load all profiles from the profiles directory.
    pub fn load(profiles_dir: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let mut profiles = BTreeMap::new();

        let dir = Path::new(profiles_dir);
        if dir.is_dir() {
            for entry in fs::read_dir(dir)? {
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    let mapping_path = entry.path().join("mapping.json");
                    if mapping_path.exists() {
                        let content = fs::read_to_string(&mapping_path)?;
                        let mapping: ProfileMapping = serde_json::from_str(&content)
                            .map_err(|e| {
                                format!(
                                    "parsing {}: {e}",
                                    mapping_path.display()
                                )
                            })?;
                        profiles.insert(name, mapping);
                    }
                }
            }
        }

        Ok(Self {
            profiles,
            profiles_dir: profiles_dir.to_string(),
        })
    }

    /// Get or create a profile by name.
    pub fn get_or_create(&mut self, name: &str) -> &mut ProfileMapping {
        self.profiles
            .entry(name.to_string())
            .or_insert_with(|| ProfileMapping {
                version: 1,
                packages: Vec::new(),
            })
    }

    /// Get a profile by name (immutable).
    pub fn get(&self, name: &str) -> Option<&ProfileMapping> {
        self.profiles.get(name)
    }

    /// List all profile names.
    pub fn list_profiles(&self) -> Vec<&str> {
        self.profiles.keys().map(|s| s.as_str()).collect()
    }

    /// Add a package to a profile and persist.
    pub fn add_package(
        &mut self,
        profile: &str,
        name: &str,
        store_path: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mapping = self.get_or_create(profile);
        mapping.add(name, store_path);
        self.persist(profile)?;
        Ok(())
    }

    /// Remove a package from a profile and persist.
    pub fn remove_package(
        &mut self,
        profile: &str,
        name: &str,
    ) -> Result<bool, Box<dyn std::error::Error>> {
        if let Some(mapping) = self.profiles.get_mut(profile) {
            let removed = mapping.remove(name);
            if removed {
                self.persist(profile)?;
            }
            Ok(removed)
        } else {
            Ok(false)
        }
    }

    /// Persist a profile mapping to disk (atomic write).
    fn persist(&self, profile: &str) -> Result<(), Box<dyn std::error::Error>> {
        let mapping = self
            .profiles
            .get(profile)
            .ok_or_else(|| format!("profile not found: {profile}"))?;

        let dir = PathBuf::from(&self.profiles_dir).join(profile);
        fs::create_dir_all(&dir)?;

        let json = serde_json::to_string_pretty(mapping)?;
        let tmp_path = dir.join("mapping.json.tmp");
        let final_path = dir.join("mapping.json");

        fs::write(&tmp_path, &json)?;
        fs::rename(&tmp_path, &final_path)?;

        Ok(())
    }

    /// Process a control command (from writes to `.control`).
    pub fn process_control(
        &mut self,
        profile: &str,
        command_json: &str,
    ) -> Result<String, Box<dyn std::error::Error>> {
        let cmd: ControlCommand = serde_json::from_str(command_json)?;

        match cmd.action.as_str() {
            "add" => {
                let store_path = cmd
                    .store_path
                    .ok_or("'add' command requires 'storePath' field")?;
                self.add_package(profile, &cmd.name, &store_path)?;
                Ok(format!("added {} to profile {}", cmd.name, profile))
            }
            "remove" => {
                let removed = self.remove_package(profile, &cmd.name)?;
                if removed {
                    Ok(format!("removed {} from profile {}", cmd.name, profile))
                } else {
                    Ok(format!("{} not found in profile {}", cmd.name, profile))
                }
            }
            "list" => {
                let mapping = self.get(profile);
                let json = serde_json::to_string_pretty(&mapping)?;
                Ok(json)
            }
            other => Err(format!("unknown control action: {other}").into()),
        }
    }
}

/// A control command written to `profile:{name}/.control`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlCommand {
    action: String,
    name: String,
    #[serde(default)]
    store_path: Option<String>,
}

/// Get current unix timestamp (seconds since epoch).
fn current_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── ProfileMapping ─────────────────────────────────────────────────

    #[test]
    fn add_and_get() {
        let mut m = ProfileMapping::default();
        m.add("ripgrep", "/nix/store/abc-ripgrep-14.1.0");

        let entry = m.get("ripgrep").unwrap();
        assert_eq!(entry.name, "ripgrep");
        assert_eq!(entry.store_path, "/nix/store/abc-ripgrep-14.1.0");
        assert!(entry.installed_at > 0);
    }

    #[test]
    fn add_replaces_existing() {
        let mut m = ProfileMapping::default();
        m.add("ripgrep", "/nix/store/old-ripgrep");
        m.add("ripgrep", "/nix/store/new-ripgrep");

        assert_eq!(m.packages.len(), 1);
        assert_eq!(m.get("ripgrep").unwrap().store_path, "/nix/store/new-ripgrep");
    }

    #[test]
    fn remove_existing() {
        let mut m = ProfileMapping::default();
        m.add("ripgrep", "/nix/store/abc-ripgrep");
        m.add("fd", "/nix/store/def-fd");

        assert!(m.remove("ripgrep"));
        assert_eq!(m.packages.len(), 1);
        assert!(m.get("ripgrep").is_none());
        assert!(m.get("fd").is_some());
    }

    #[test]
    fn remove_nonexistent() {
        let mut m = ProfileMapping::default();
        assert!(!m.remove("nonexistent"));
    }

    #[test]
    fn resolve_path_finds_file() {
        let tmp = tempfile::tempdir().unwrap();

        // Create a fake store path with bin/rg.
        let store_path = tmp.path().join("abc-ripgrep");
        fs::create_dir_all(store_path.join("bin")).unwrap();
        fs::write(store_path.join("bin/rg"), "#!/bin/sh").unwrap();

        let mut m = ProfileMapping::default();
        m.packages.push(ProfileEntry {
            name: "ripgrep".to_string(),
            store_path: store_path.to_str().unwrap().to_string(),
            installed_at: 1000,
        });

        let resolved = m.resolve_path("bin/rg").unwrap();
        assert_eq!(resolved.package_name, "ripgrep");
        assert!(resolved.full_path.ends_with("bin/rg"));
    }

    #[test]
    fn resolve_path_last_installed_wins() {
        let tmp = tempfile::tempdir().unwrap();

        // Two packages both provide bin/foo.
        let pkg_a = tmp.path().join("a-pkg");
        fs::create_dir_all(pkg_a.join("bin")).unwrap();
        fs::write(pkg_a.join("bin/foo"), "from a").unwrap();

        let pkg_b = tmp.path().join("b-pkg");
        fs::create_dir_all(pkg_b.join("bin")).unwrap();
        fs::write(pkg_b.join("bin/foo"), "from b").unwrap();

        let mut m = ProfileMapping::default();
        m.packages.push(ProfileEntry {
            name: "a".to_string(),
            store_path: pkg_a.to_str().unwrap().to_string(),
            installed_at: 1000,
        });
        m.packages.push(ProfileEntry {
            name: "b".to_string(),
            store_path: pkg_b.to_str().unwrap().to_string(),
            installed_at: 2000,
        });

        let resolved = m.resolve_path("bin/foo").unwrap();
        assert_eq!(resolved.package_name, "b"); // Last installed wins.
    }

    #[test]
    fn resolve_path_not_found() {
        let m = ProfileMapping::default();
        assert!(m.resolve_path("bin/nonexistent").is_none());
    }

    #[test]
    fn list_union_merges_dirs() {
        let tmp = tempfile::tempdir().unwrap();

        let pkg_a = tmp.path().join("a-pkg");
        fs::create_dir_all(pkg_a.join("bin")).unwrap();
        fs::write(pkg_a.join("bin/a-tool"), "").unwrap();
        fs::write(pkg_a.join("bin/shared"), "from a").unwrap();

        let pkg_b = tmp.path().join("b-pkg");
        fs::create_dir_all(pkg_b.join("bin")).unwrap();
        fs::write(pkg_b.join("bin/b-tool"), "").unwrap();
        fs::write(pkg_b.join("bin/shared"), "from b").unwrap();

        let mut m = ProfileMapping::default();
        m.packages.push(ProfileEntry {
            name: "a".to_string(),
            store_path: pkg_a.to_str().unwrap().to_string(),
            installed_at: 1000,
        });
        m.packages.push(ProfileEntry {
            name: "b".to_string(),
            store_path: pkg_b.to_str().unwrap().to_string(),
            installed_at: 2000,
        });

        let entries = m.list_union("bin");
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();

        // All unique names from both packages.
        assert!(names.contains(&"a-tool"));
        assert!(names.contains(&"b-tool"));
        assert!(names.contains(&"shared"));
        assert_eq!(entries.len(), 3); // Deduplicated.

        // "shared" should come from b (last installed).
        let shared = entries.iter().find(|e| e.name == "shared").unwrap();
        assert_eq!(shared.from_package, "b");
    }

    #[test]
    fn list_union_empty_profile() {
        let m = ProfileMapping::default();
        let entries = m.list_union("bin");
        assert!(entries.is_empty());
    }

    // ── ProfileStore ───────────────────────────────────────────────────

    #[test]
    fn profile_store_persistence() {
        let tmp = tempfile::tempdir().unwrap();
        let profiles_dir = tmp.path().to_str().unwrap();

        // Create and persist.
        {
            let mut store = ProfileStore::load(profiles_dir).unwrap();
            store
                .add_package("default", "ripgrep", "/nix/store/abc-rg")
                .unwrap();
            store
                .add_package("default", "fd", "/nix/store/def-fd")
                .unwrap();
        }

        // Reload from disk.
        {
            let store = ProfileStore::load(profiles_dir).unwrap();
            let mapping = store.get("default").unwrap();
            assert_eq!(mapping.packages.len(), 2);
            assert!(mapping.get("ripgrep").is_some());
            assert!(mapping.get("fd").is_some());
        }
    }

    #[test]
    fn profile_store_list_profiles() {
        let tmp = tempfile::tempdir().unwrap();
        let profiles_dir = tmp.path().to_str().unwrap();

        let mut store = ProfileStore::load(profiles_dir).unwrap();
        store
            .add_package("default", "x", "/nix/store/x")
            .unwrap();
        store
            .add_package("dev", "y", "/nix/store/y")
            .unwrap();

        let mut names = store.list_profiles();
        names.sort();
        assert_eq!(names, vec!["default", "dev"]);
    }

    #[test]
    fn profile_store_remove() {
        let tmp = tempfile::tempdir().unwrap();
        let profiles_dir = tmp.path().to_str().unwrap();

        let mut store = ProfileStore::load(profiles_dir).unwrap();
        store
            .add_package("default", "rg", "/nix/store/rg")
            .unwrap();
        store
            .add_package("default", "fd", "/nix/store/fd")
            .unwrap();

        assert!(store.remove_package("default", "rg").unwrap());
        assert!(!store.remove_package("default", "nonexistent").unwrap());

        let mapping = store.get("default").unwrap();
        assert_eq!(mapping.packages.len(), 1);
        assert!(mapping.get("fd").is_some());
    }

    #[test]
    fn profile_store_atomic_write() {
        let tmp = tempfile::tempdir().unwrap();
        let profiles_dir = tmp.path().to_str().unwrap();

        let mut store = ProfileStore::load(profiles_dir).unwrap();
        store
            .add_package("default", "x", "/nix/store/x")
            .unwrap();

        // The mapping.json should exist, not mapping.json.tmp.
        let mapping_path = tmp.path().join("default/mapping.json");
        let tmp_path = tmp.path().join("default/mapping.json.tmp");

        assert!(mapping_path.exists());
        assert!(!tmp_path.exists());
    }

    // ── Control Commands ───────────────────────────────────────────────

    #[test]
    fn control_add() {
        let tmp = tempfile::tempdir().unwrap();
        let mut store = ProfileStore::load(tmp.path().to_str().unwrap()).unwrap();

        let result = store
            .process_control(
                "default",
                r#"{"action": "add", "name": "ripgrep", "storePath": "/nix/store/abc-rg"}"#,
            )
            .unwrap();

        assert!(result.contains("added"));
        assert!(store.get("default").unwrap().get("ripgrep").is_some());
    }

    #[test]
    fn control_remove() {
        let tmp = tempfile::tempdir().unwrap();
        let mut store = ProfileStore::load(tmp.path().to_str().unwrap()).unwrap();

        store
            .add_package("default", "rg", "/nix/store/rg")
            .unwrap();

        let result = store
            .process_control("default", r#"{"action": "remove", "name": "rg"}"#)
            .unwrap();

        assert!(result.contains("removed"));
        assert!(store.get("default").unwrap().get("rg").is_none());
    }

    #[test]
    fn control_list() {
        let tmp = tempfile::tempdir().unwrap();
        let mut store = ProfileStore::load(tmp.path().to_str().unwrap()).unwrap();

        store
            .add_package("default", "rg", "/nix/store/rg")
            .unwrap();

        let result = store
            .process_control("default", r#"{"action": "list", "name": ""}"#)
            .unwrap();

        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert!(parsed["packages"].is_array());
    }

    #[test]
    fn control_unknown_action() {
        let tmp = tempfile::tempdir().unwrap();
        let mut store = ProfileStore::load(tmp.path().to_str().unwrap()).unwrap();

        let result = store.process_control(
            "default",
            r#"{"action": "bogus", "name": "x"}"#,
        );
        assert!(result.is_err());
    }

    #[test]
    fn control_add_missing_store_path() {
        let tmp = tempfile::tempdir().unwrap();
        let mut store = ProfileStore::load(tmp.path().to_str().unwrap()).unwrap();

        let result = store.process_control(
            "default",
            r#"{"action": "add", "name": "rg"}"#,
        );
        assert!(result.is_err());
    }

    // ── Serialization ──────────────────────────────────────────────────

    #[test]
    fn mapping_serde_roundtrip() {
        let mut m = ProfileMapping {
            version: 1,
            packages: Vec::new(),
        };
        m.add("ripgrep", "/nix/store/abc-rg");
        m.add("fd", "/nix/store/def-fd");

        let json = serde_json::to_string_pretty(&m).unwrap();
        let parsed: ProfileMapping = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.packages.len(), 2);
        assert_eq!(parsed.packages[0].name, "ripgrep");
        assert_eq!(parsed.packages[1].name, "fd");
    }

    #[test]
    fn entry_serde_camel_case() {
        let entry = ProfileEntry {
            name: "test".to_string(),
            store_path: "/nix/store/abc".to_string(),
            installed_at: 12345,
        };

        let json = serde_json::to_string(&entry).unwrap();
        assert!(json.contains("storePath"));
        assert!(json.contains("installedAt"));
        assert!(!json.contains("store_path"));
    }
}
