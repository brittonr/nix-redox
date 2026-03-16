//! BLAKE3 manifest hasher for RedoxOS rootTree.
//!
//! Reads a base manifest.json, walks the root tree computing BLAKE3 hashes
//! of each file (skipping excluded paths and symlinks), computes a buildHash
//! from the sorted inventory, writes the final manifest, and seeds generation 1.
//!
//! Usage: hash-manifest <root-dir>

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

const MANIFEST_REL: &str = "etc/redox-system/manifest.json";
const GENERATIONS_PREFIX: &str = "etc/redox-system/generations/";
const STORE_PREFIX: &str = "nix/store/";

fn should_skip(relpath: &str) -> bool {
    relpath == MANIFEST_REL
        || relpath.starts_with(GENERATIONS_PREFIX)
        || relpath.starts_with(STORE_PREFIX)
}

fn octal_mode(mode: u32) -> String {
    format!("{:o}", mode & 0o7777)
}

fn hash_root_tree(root: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let manifest_path = root.join(MANIFEST_REL);
    if !manifest_path.exists() {
        return Err(format!("{} not found", manifest_path.display()).into());
    }

    // Read base manifest
    let manifest_text = fs::read_to_string(&manifest_path)?;
    let mut manifest: serde_json::Value = serde_json::from_str(&manifest_text)?;

    // Walk tree and compute BLAKE3 hashes
    // BTreeMap gives us sorted keys automatically.
    let mut inventory: BTreeMap<String, serde_json::Value> = BTreeMap::new();

    for entry in WalkDir::new(root).sort_by_file_name() {
        let entry = entry?;

        // Skip directories
        if entry.file_type().is_dir() {
            continue;
        }

        // Skip symlinks
        if entry.path_is_symlink() {
            continue;
        }

        let path = entry.path();
        let relpath = match path.strip_prefix(root) {
            Ok(r) => r.to_string_lossy().to_string(),
            Err(_) => continue,
        };

        if should_skip(&relpath) {
            continue;
        }

        let data = fs::read(path)?;
        let hash = blake3::hash(&data).to_hex().to_string();
        let meta = fs::metadata(path)?;

        inventory.insert(
            relpath,
            serde_json::json!({
                "blake3": hash,
                "size": meta.len(),
                "mode": octal_mode(meta.mode()),
            }),
        );
    }

    // Compute buildHash from the sorted file inventory (BLAKE3)
    let inventory_json = serde_json::to_string(&inventory)?;
    let build_hash = blake3::hash(inventory_json.as_bytes()).to_hex().to_string();

    // Merge file inventory and buildHash into manifest
    manifest["files"] = serde_json::Value::Object(
        inventory
            .into_iter()
            .collect::<serde_json::Map<String, serde_json::Value>>(),
    );

    if let Some(gen) = manifest.get_mut("generation") {
        gen["buildHash"] = serde_json::Value::String(build_hash);
    }

    // Write final manifest (sorted keys, indented)
    let final_json = serde_json::to_string_pretty(&manifest)?;
    fs::write(&manifest_path, &final_json)?;

    // Seed generation 1
    let gen_dir = root.join("etc/redox-system/generations/1");
    fs::create_dir_all(&gen_dir)?;
    fs::write(gen_dir.join("manifest.json"), &final_json)?;

    // Print summary
    let file_count = manifest["files"]
        .as_object()
        .map(|m| m.len())
        .unwrap_or(0);
    println!("  Manifest: {} tracked files", file_count);

    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: hash-manifest <root-dir>");
        std::process::exit(1);
    }

    let root = PathBuf::from(&args[1]);
    if !root.is_dir() {
        eprintln!("Error: {} is not a directory", root.display());
        std::process::exit(1);
    }

    if let Err(e) = hash_root_tree(&root) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn make_base_manifest() -> serde_json::Value {
        serde_json::json!({
            "manifestVersion": 1,
            "system": { "redoxSystemVersion": "0.5.0" },
            "generation": {
                "id": 1,
                "buildHash": "",
                "description": "initial build",
                "timestamp": ""
            },
            "packages": []
        })
    }

    #[test]
    fn test_computes_hashes_and_build_hash() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();

        // Create manifest
        let manifest_dir = root.join("etc/redox-system");
        fs::create_dir_all(&manifest_dir).unwrap();
        fs::write(
            manifest_dir.join("manifest.json"),
            serde_json::to_string_pretty(&make_base_manifest()).unwrap(),
        )
        .unwrap();

        // Create a test file
        fs::create_dir_all(root.join("etc")).unwrap();
        fs::write(root.join("etc/hostname"), "redox\n").unwrap();

        hash_root_tree(root).unwrap();

        // Read result
        let result: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(manifest_dir.join("manifest.json")).unwrap())
                .unwrap();

        // files key populated
        let files = result["files"].as_object().unwrap();
        assert!(files.contains_key("etc/hostname"));
        assert!(files["etc/hostname"]["blake3"].as_str().unwrap().len() == 64);
        assert!(files["etc/hostname"]["size"].as_u64().unwrap() == 6);

        // buildHash present and non-empty
        let build_hash = result["generation"]["buildHash"].as_str().unwrap();
        assert!(!build_hash.is_empty());
        assert_eq!(build_hash.len(), 64);
    }

    #[test]
    fn test_skips_excluded_paths() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();

        let manifest_dir = root.join("etc/redox-system");
        fs::create_dir_all(&manifest_dir).unwrap();
        fs::write(
            manifest_dir.join("manifest.json"),
            serde_json::to_string_pretty(&make_base_manifest()).unwrap(),
        )
        .unwrap();

        // Create excluded files
        let gen_dir = root.join("etc/redox-system/generations/0");
        fs::create_dir_all(&gen_dir).unwrap();
        fs::write(gen_dir.join("old.json"), "{}").unwrap();

        let store_dir = root.join("nix/store/abc-pkg");
        fs::create_dir_all(&store_dir).unwrap();
        fs::write(store_dir.join("bin"), "binary").unwrap();

        // Create a non-excluded file
        fs::write(root.join("etc/hostname"), "redox\n").unwrap();

        hash_root_tree(root).unwrap();

        let result: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(manifest_dir.join("manifest.json")).unwrap())
                .unwrap();

        let files = result["files"].as_object().unwrap();
        // hostname is tracked
        assert!(files.contains_key("etc/hostname"));
        // excluded paths are absent
        assert!(!files.contains_key("etc/redox-system/manifest.json"));
        assert!(!files.contains_key("etc/redox-system/generations/0/old.json"));
        assert!(!files.contains_key("nix/store/abc-pkg/bin"));
    }

    #[test]
    fn test_skips_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();

        let manifest_dir = root.join("etc/redox-system");
        fs::create_dir_all(&manifest_dir).unwrap();
        fs::write(
            manifest_dir.join("manifest.json"),
            serde_json::to_string_pretty(&make_base_manifest()).unwrap(),
        )
        .unwrap();

        // Real file
        fs::write(root.join("etc/hostname"), "redox\n").unwrap();
        // Symlink
        std::os::unix::fs::symlink("/dev/null", root.join("etc/link")).unwrap();

        hash_root_tree(root).unwrap();

        let result: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(manifest_dir.join("manifest.json")).unwrap())
                .unwrap();

        let files = result["files"].as_object().unwrap();
        assert!(files.contains_key("etc/hostname"));
        assert!(!files.contains_key("etc/link"));
    }

    #[test]
    fn test_seeds_generation_1() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();

        let manifest_dir = root.join("etc/redox-system");
        fs::create_dir_all(&manifest_dir).unwrap();
        fs::write(
            manifest_dir.join("manifest.json"),
            serde_json::to_string_pretty(&make_base_manifest()).unwrap(),
        )
        .unwrap();

        fs::write(root.join("etc/hostname"), "redox\n").unwrap();

        hash_root_tree(root).unwrap();

        let gen1_path = root.join("etc/redox-system/generations/1/manifest.json");
        assert!(gen1_path.exists());

        // Generation 1 manifest matches the final manifest
        let main_manifest = fs::read_to_string(manifest_dir.join("manifest.json")).unwrap();
        let gen1_manifest = fs::read_to_string(&gen1_path).unwrap();
        assert_eq!(main_manifest, gen1_manifest);
    }
}
