//! Local filesystem binary cache reader.
//!
//! Reads Nix binary cache format from a local directory (e.g. /nix/cache/).
//! Same format as HTTP binary caches but accessed via filesystem I/O.
//!
//! Layout:
//!   /nix/cache/nix-cache-info    — cache metadata
//!   /nix/cache/packages.json     — name → store path index
//!   /nix/cache/{hash}.narinfo    — per-path metadata
//!   /nix/cache/nar/*.nar.zst     — compressed NAR files

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};


/// Default local cache path on Redox.
pub const DEFAULT_CACHE_PATH: &str = "/nix/cache";

/// Package index entry from packages.json.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageEntry {
    pub store_path: String,
    pub pname: String,
    pub version: String,
    pub nar_hash: Option<String>,
    pub nar_size: Option<u64>,
    pub file_size: Option<u64>,
    pub compatibility: Option<Compatibility>,
}

/// Versioned artifact evidence; native targets are build declarations, not names.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Compatibility {
    pub version: u32,
    pub kind: String,
    pub target: String,
    pub evidence: String,
}

/// Package index (packages.json).
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageIndex {
    pub version: u32,
    pub packages: BTreeMap<String, PackageEntry>,
    pub closure_manifest_version: Option<u32>,
    pub installation_mode: Option<String>,
}

impl PackageIndex {
    /// Version 1 is the legacy standalone catalog. Version 2 requires complete
    /// narinfo traversal and compatibility evidence on every advertised root.
    pub fn validate(&self) -> Result<(), Box<dyn std::error::Error>> {
        match self.version {
            1 => return Ok(()),
            2 => {}
            version => return Err(format!("unsupported package-index version: {version}").into()),
        }
        if self.closure_manifest_version != Some(1)
            || self.installation_mode.as_deref() != Some("recursive")
        {
            return Err("package-index v2 requires closure manifest v1 and recursive installation".into());
        }
        for (name, entry) in &self.packages {
            let compatibility = entry.compatibility.as_ref()
                .ok_or_else(|| format!("package '{name}' lacks compatibility evidence"))?;
            if compatibility.version != 1 || compatibility.evidence.is_empty() {
                return Err(format!("unsupported compatibility evidence for package '{name}'").into());
            }
            let compatible = match compatibility.kind.as_str() {
                "native" => compatibility.target == "x86_64-unknown-redox",
                "script" | "data" => compatibility.target == "any",
                _ => false,
            };
            if !compatible {
                return Err(format!("wrong-target package '{name}': {} ({})",
                    compatibility.target, compatibility.kind).into());
            }
        }
        Ok(())
    }
}

/// Read the package index from a local cache.
pub fn read_index(cache_path: &str) -> Result<PackageIndex, Box<dyn std::error::Error>> {
    let index_path = PathBuf::from(cache_path).join("packages.json");
    let content = std::fs::read_to_string(&index_path)
        .map_err(|e| format!("cannot read {}: {e}", index_path.display()))?;
    let index: PackageIndex = serde_json::from_str(&content)?;
    index.validate()?;
    Ok(index)
}

/// Search for packages matching a pattern.
pub fn search(cache_path: &str, pattern: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let index = read_index(cache_path)?;

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
            eprintln!("No packages in cache");
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

/// Fetch a store path from a local binary cache.
///
/// Restore the entire narinfo reference closure using the common verified
/// installer, without advertising dependencies as separate profile packages.
pub fn fetch_local(store_path: &str, cache_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    crate::install::fetch_and_extract(
        store_path,
        &crate::cache_source::CacheSource::Local(PathBuf::from(cache_path)),
    )
}

// ─── Helpers ───────────────────────────────────────────────────────────────


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
    fn parse_package_index() {
        let json = r#"{
            "version": 1,
            "packages": {
                "ripgrep": {
                    "storePath": "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-ripgrep-14.1.0",
                    "pname": "ripgrep",
                    "version": "14.1.0",
                    "narHash": "sha256:abc123",
                    "narSize": 5000000,
                    "fileSize": 2000000
                }
            }
        }"#;

        let index: PackageIndex = serde_json::from_str(json).unwrap();
        assert_eq!(index.version, 1);
        assert_eq!(index.packages.len(), 1);

        let rg = &index.packages["ripgrep"];
        assert_eq!(rg.pname, "ripgrep");
        assert_eq!(rg.version, "14.1.0");
        assert_eq!(rg.file_size, Some(2000000));
    }

    #[test]
    fn format_sizes() {
        assert_eq!(format_size(0), "0 B");
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(1024), "1 KB");
        assert_eq!(format_size(1536), "2 KB");
        assert_eq!(format_size(1048576), "1.0 MB");
        assert_eq!(format_size(5242880), "5.0 MB");
    }

    #[test]
    fn package_index_missing_optional_fields() {
        let json = r#"{
            "version": 1,
            "packages": {
                "test": {
                    "storePath": "/nix/store/00bgd045z0d4icpbc2yyz4gx48ak44la-test-1.0",
                    "pname": "test",
                    "version": "1.0"
                }
            }
        }"#;

        let index: PackageIndex = serde_json::from_str(json).unwrap();
        let pkg = &index.packages["test"];
        assert_eq!(pkg.nar_hash, None);
        assert_eq!(pkg.nar_size, None);
        assert_eq!(pkg.file_size, None);
    }

    #[test]
    fn package_index_v2_requires_known_schema_and_target_evidence() {
        let value = serde_json::json!({
            "version": 2,
            "closureManifestVersion": 1,
            "installationMode": "recursive",
            "packages": { "fixture": {
                "storePath": "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fixture",
                "pname": "fixture", "version": "1",
                "compatibility": { "version": 1, "kind": "native",
                    "target": "x86_64-unknown-redox", "evidence": "derivation.TARGET" }
            }}
        });
        let parse = |value: &serde_json::Value| serde_json::from_value::<PackageIndex>(value.clone()).unwrap();
        assert!(parse(&value).validate().is_ok());
        let mut bad = value.clone();
        bad["version"] = serde_json::json!(99);
        assert!(parse(&bad).validate().unwrap_err().to_string().contains("unsupported package-index"));
        bad = value.clone();
        bad["closureManifestVersion"] = serde_json::json!(99);
        assert!(parse(&bad).validate().is_err());
        bad = value.clone();
        bad["packages"]["fixture"]["compatibility"]["target"] = serde_json::json!("x86_64-linux");
        assert!(parse(&bad).validate().unwrap_err().to_string().contains("wrong-target"));
        bad = value.clone();
        bad["packages"]["fixture"]["compatibility"] = serde_json::Value::Null;
        assert!(parse(&bad).validate().unwrap_err().to_string().contains("lacks compatibility"));
        for kind in ["script", "data"] {
            let mut portable = value.clone();
            portable["packages"]["fixture"]["compatibility"]["kind"] = serde_json::json!(kind);
            portable["packages"]["fixture"]["compatibility"]["target"] = serde_json::json!("any");
            assert!(parse(&portable).validate().is_ok());
        }
    }
}
