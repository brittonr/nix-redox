//! System introspection commands for RedoxOS.
//!
//! Reads `/etc/redox-system/manifest.json` embedded at build time and
//! provides commands for querying, verifying, and diffing the running
//! system configuration.
//!
//! Commands:
//!   - `snix system info`   — display system metadata and configuration
//!   - `snix system verify` — check all tracked files against manifest hashes
//!   - `snix system diff`   — compare current manifest with another

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Default manifest path on the running Redox system
const MANIFEST_PATH: &str = "/etc/redox-system/manifest.json";

// ===== Manifest Schema =====

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub manifest_version: u32,
    pub system: SystemInfo,
    pub configuration: Configuration,
    pub packages: Vec<Package>,
    pub drivers: Drivers,
    pub users: BTreeMap<String, User>,
    pub groups: BTreeMap<String, Group>,
    pub services: Services,
    #[serde(default)]
    pub files: BTreeMap<String, FileInfo>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SystemInfo {
    pub redox_system_version: String,
    pub target: String,
    pub profile: String,
    pub hostname: String,
    pub timezone: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Configuration {
    pub boot: BootConfig,
    pub hardware: HardwareConfig,
    pub networking: NetworkingConfig,
    pub graphics: GraphicsConfig,
    pub security: SecurityConfig,
    pub logging: LoggingConfig,
    pub power: PowerConfig,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct BootConfig {
    #[serde(rename = "diskSizeMB")]
    pub disk_size_mb: u32,
    #[serde(rename = "espSizeMB")]
    pub esp_size_mb: u32,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct HardwareConfig {
    pub storage_drivers: Vec<String>,
    pub network_drivers: Vec<String>,
    pub graphics_drivers: Vec<String>,
    pub audio_drivers: Vec<String>,
    pub usb_enabled: bool,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct NetworkingConfig {
    pub enabled: bool,
    pub mode: String,
    pub dns: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct GraphicsConfig {
    pub enabled: bool,
    pub resolution: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SecurityConfig {
    pub protect_kernel_schemes: bool,
    pub require_passwords: bool,
    pub allow_remote_root: bool,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct LoggingConfig {
    pub log_level: String,
    pub kernel_log_level: String,
    pub log_to_file: bool,
    #[serde(rename = "maxLogSizeMB")]
    pub max_log_size_mb: u32,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PowerConfig {
    pub acpi_enabled: bool,
    pub power_action: String,
    pub reboot_on_panic: bool,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Package {
    pub name: String,
    pub version: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Drivers {
    pub all: Vec<String>,
    pub initfs: Vec<String>,
    pub core: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct User {
    pub uid: u32,
    pub gid: u32,
    pub home: String,
    pub shell: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Group {
    pub gid: u32,
    pub members: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Services {
    pub init_scripts: Vec<String>,
    pub startup_script: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct FileInfo {
    pub sha256: String,
    pub size: u64,
    pub mode: String,
}

// ===== Manifest Loading =====

fn load_manifest_from(path: &str) -> Result<Manifest, Box<dyn std::error::Error>> {
    let p = Path::new(path);
    if !p.exists() {
        return Err(format!("manifest not found: {path}\nIs this a Redox system built with the module system?").into());
    }
    let content = fs::read_to_string(p)?;
    let manifest: Manifest = serde_json::from_str(&content)?;
    Ok(manifest)
}

fn load_manifest() -> Result<Manifest, Box<dyn std::error::Error>> {
    load_manifest_from(MANIFEST_PATH)
}

// ===== Commands =====

/// Display system information from the embedded manifest
pub fn info(manifest_path: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let manifest = match manifest_path {
        Some(p) => load_manifest_from(p)?,
        None => load_manifest()?,
    };

    println!("RedoxOS System Information");
    println!("==========================");
    println!();
    println!("System:");
    println!("  Version:    {}", manifest.system.redox_system_version);
    println!("  Target:     {}", manifest.system.target);
    println!("  Profile:    {}", manifest.system.profile);
    println!("  Hostname:   {}", manifest.system.hostname);
    println!("  Timezone:   {}", manifest.system.timezone);
    println!();

    let cfg = &manifest.configuration;
    println!("Configuration:");
    println!("  Disk:       {} MB (ESP {} MB)", cfg.boot.disk_size_mb, cfg.boot.esp_size_mb);
    println!("  Networking: {} ({})",
        if cfg.networking.enabled { "enabled" } else { "disabled" },
        cfg.networking.mode);
    if !cfg.networking.dns.is_empty() {
        println!("  DNS:        {}", cfg.networking.dns.join(", "));
    }
    println!("  Graphics:   {}",
        if cfg.graphics.enabled {
            format!("enabled ({})", cfg.graphics.resolution)
        } else {
            "disabled".to_string()
        });
    println!("  Security:   kernel-protect={} require-pw={} remote-root={}",
        cfg.security.protect_kernel_schemes,
        cfg.security.require_passwords,
        cfg.security.allow_remote_root);
    println!("  Logging:    level={} kernel={} file={}",
        cfg.logging.log_level, cfg.logging.kernel_log_level, cfg.logging.log_to_file);
    println!("  Power:      acpi={} action={} reboot-on-panic={}",
        cfg.power.acpi_enabled, cfg.power.power_action, cfg.power.reboot_on_panic);
    println!();

    println!("Packages:     {} installed", manifest.packages.len());
    for pkg in &manifest.packages {
        if pkg.version.is_empty() {
            println!("  - {}", pkg.name);
        } else {
            println!("  - {} {}", pkg.name, pkg.version);
        }
    }
    println!();

    println!("Drivers:      {} total", manifest.drivers.all.len());
    for drv in &manifest.drivers.all {
        println!("  - {drv}");
    }
    println!();

    println!("Users:        {}", manifest.users.len());
    for (name, user) in &manifest.users {
        println!("  - {name} (uid={} gid={} home={})", user.uid, user.gid, user.home);
    }
    println!();

    println!("Services:     {} init scripts", manifest.services.init_scripts.len());
    for svc in &manifest.services.init_scripts {
        println!("  - {svc}");
    }
    println!();

    println!("Files:        {} tracked", manifest.files.len());

    Ok(())
}

/// Verify system files against manifest hashes
pub fn verify(
    manifest_path: Option<&str>,
    verbose: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let manifest = match manifest_path {
        Some(p) => load_manifest_from(p)?,
        None => load_manifest()?,
    };

    if manifest.files.is_empty() {
        eprintln!("warning: manifest has no file inventory — nothing to verify");
        return Ok(());
    }

    println!("Verifying {} tracked files...", manifest.files.len());
    println!();

    let mut verified: u32 = 0;
    let mut modified: u32 = 0;
    let mut missing: u32 = 0;
    let mut errors: Vec<String> = Vec::new();

    let mut sorted_files: Vec<_> = manifest.files.iter().collect();
    sorted_files.sort_by_key(|(path, _)| path.as_str());

    for (path, expected) in &sorted_files {
        let full_path = Path::new("/").join(path);

        if !full_path.exists() {
            missing += 1;
            errors.push(format!("  MISSING  {path}"));
            continue;
        }

        match hash_file(&full_path) {
            Ok(actual_hash) => {
                if actual_hash == expected.sha256 {
                    verified += 1;
                    if verbose {
                        println!("  OK       {path}");
                    }
                } else {
                    modified += 1;
                    errors.push(format!(
                        "  CHANGED  {path}  (expected {}…, got {}…)",
                        &expected.sha256[..12],
                        &actual_hash[..12]
                    ));
                }
            }
            Err(e) => {
                errors.push(format!("  ERROR    {path}: {e}"));
            }
        }
    }

    println!("Results:");
    println!("  Verified:  {verified}");
    if modified > 0 {
        println!("  Modified:  {modified}");
    }
    if missing > 0 {
        println!("  Missing:   {missing}");
    }

    if !errors.is_empty() {
        println!();
        println!("Issues:");
        for err in &errors {
            println!("{err}");
        }
        println!();
        return Err(format!(
            "{} file(s) failed verification ({modified} modified, {missing} missing)",
            modified + missing
        )
        .into());
    }

    println!();
    println!("All {verified} files verified successfully.");
    Ok(())
}

/// Compare two manifests and show differences
pub fn diff(other_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let current = load_manifest()?;
    let other = load_manifest_from(other_path)?;

    let mut has_diff = false;

    // System metadata
    if current.system.redox_system_version != other.system.redox_system_version {
        println!("Version: {} -> {}", current.system.redox_system_version, other.system.redox_system_version);
        has_diff = true;
    }
    if current.system.profile != other.system.profile {
        println!("Profile: {} -> {}", current.system.profile, other.system.profile);
        has_diff = true;
    }
    if current.system.hostname != other.system.hostname {
        println!("Hostname: {} -> {}", current.system.hostname, other.system.hostname);
        has_diff = true;
    }

    // Package diff
    let cur_pkgs: BTreeMap<_, _> = current.packages.iter().map(|p| (&p.name, &p.version)).collect();
    let oth_pkgs: BTreeMap<_, _> = other.packages.iter().map(|p| (&p.name, &p.version)).collect();

    let mut pkg_changes = Vec::new();
    for (name, ver) in &cur_pkgs {
        match oth_pkgs.get(name) {
            None => pkg_changes.push(format!("  + {name} {ver}")),
            Some(ov) if ov != ver => pkg_changes.push(format!("  ~ {name} {ov} -> {ver}")),
            _ => {}
        }
    }
    for (name, ver) in &oth_pkgs {
        if !cur_pkgs.contains_key(name) {
            pkg_changes.push(format!("  - {name} {ver}"));
        }
    }

    if !pkg_changes.is_empty() {
        if has_diff {
            println!();
        }
        println!("Packages:");
        for change in &pkg_changes {
            println!("{change}");
        }
        has_diff = true;
    }

    // Driver diff
    let cur_drvs: std::collections::BTreeSet<_> = current.drivers.all.iter().collect();
    let oth_drvs: std::collections::BTreeSet<_> = other.drivers.all.iter().collect();
    let added_drvs: Vec<_> = cur_drvs.difference(&oth_drvs).collect();
    let removed_drvs: Vec<_> = oth_drvs.difference(&cur_drvs).collect();

    if !added_drvs.is_empty() || !removed_drvs.is_empty() {
        if has_diff {
            println!();
        }
        println!("Drivers:");
        for d in &added_drvs {
            println!("  + {d}");
        }
        for d in &removed_drvs {
            println!("  - {d}");
        }
        has_diff = true;
    }

    // User diff
    let mut user_changes = Vec::new();
    for (name, _) in &current.users {
        if !other.users.contains_key(name) {
            user_changes.push(format!("  + {name}"));
        }
    }
    for (name, _) in &other.users {
        if !current.users.contains_key(name) {
            user_changes.push(format!("  - {name}"));
        }
    }
    if !user_changes.is_empty() {
        if has_diff {
            println!();
        }
        println!("Users:");
        for change in &user_changes {
            println!("{change}");
        }
        has_diff = true;
    }

    // Configuration changes
    let mut cfg_changes = Vec::new();
    let cc = &current.configuration;
    let oc = &other.configuration;

    if cc.networking.enabled != oc.networking.enabled {
        cfg_changes.push(format!(
            "  networking.enabled: {} -> {}",
            oc.networking.enabled, cc.networking.enabled
        ));
    }
    if cc.networking.mode != oc.networking.mode {
        cfg_changes.push(format!(
            "  networking.mode: {} -> {}",
            oc.networking.mode, cc.networking.mode
        ));
    }
    if cc.graphics.enabled != oc.graphics.enabled {
        cfg_changes.push(format!(
            "  graphics.enabled: {} -> {}",
            oc.graphics.enabled, cc.graphics.enabled
        ));
    }
    if cc.boot.disk_size_mb != oc.boot.disk_size_mb {
        cfg_changes.push(format!(
            "  boot.diskSizeMB: {} -> {}",
            oc.boot.disk_size_mb, cc.boot.disk_size_mb
        ));
    }
    if cc.security.protect_kernel_schemes != oc.security.protect_kernel_schemes {
        cfg_changes.push(format!(
            "  security.protectKernelSchemes: {} -> {}",
            oc.security.protect_kernel_schemes, cc.security.protect_kernel_schemes
        ));
    }

    if !cfg_changes.is_empty() {
        if has_diff {
            println!();
        }
        println!("Configuration:");
        for change in &cfg_changes {
            println!("{change}");
        }
        has_diff = true;
    }

    // File diff
    let cur_files: std::collections::BTreeSet<_> = current.files.keys().collect();
    let oth_files: std::collections::BTreeSet<_> = other.files.keys().collect();
    let added_files: Vec<_> = cur_files.difference(&oth_files).collect();
    let removed_files: Vec<_> = oth_files.difference(&cur_files).collect();
    let changed_files: Vec<_> = cur_files
        .intersection(&oth_files)
        .filter(|f| current.files[**f].sha256 != other.files[**f].sha256)
        .collect();

    if !added_files.is_empty() || !removed_files.is_empty() || !changed_files.is_empty() {
        if has_diff {
            println!();
        }
        println!("Files ({} added, {} removed, {} changed):",
            added_files.len(), removed_files.len(), changed_files.len());
        for f in added_files.iter().take(20) {
            println!("  + {f}");
        }
        for f in removed_files.iter().take(20) {
            println!("  - {f}");
        }
        for f in changed_files.iter().take(20) {
            println!("  ~ {f}");
        }
        let total = added_files.len() + removed_files.len() + changed_files.len();
        if total > 60 {
            println!("  ... and {} more", total - 60);
        }
        has_diff = true;
    }

    if !has_diff {
        println!("No differences.");
    }

    Ok(())
}

// ===== Helpers =====

fn hash_file(path: &Path) -> std::io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let hash = hasher.finalize();
    Ok(format!("{:x}", hash))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_manifest() -> Manifest {
        Manifest {
            manifest_version: 1,
            system: SystemInfo {
                redox_system_version: "0.4.0".to_string(),
                target: "x86_64-unknown-redox".to_string(),
                profile: "redox".to_string(),
                hostname: "test-host".to_string(),
                timezone: "UTC".to_string(),
            },
            configuration: Configuration {
                boot: BootConfig {
                    disk_size_mb: 512,
                    esp_size_mb: 200,
                },
                hardware: HardwareConfig {
                    storage_drivers: vec!["virtio-blkd".to_string()],
                    network_drivers: vec!["virtio-netd".to_string()],
                    graphics_drivers: vec![],
                    audio_drivers: vec![],
                    usb_enabled: false,
                },
                networking: NetworkingConfig {
                    enabled: true,
                    mode: "auto".to_string(),
                    dns: vec!["1.1.1.1".to_string()],
                },
                graphics: GraphicsConfig {
                    enabled: false,
                    resolution: "1024x768".to_string(),
                },
                security: SecurityConfig {
                    protect_kernel_schemes: true,
                    require_passwords: false,
                    allow_remote_root: false,
                },
                logging: LoggingConfig {
                    log_level: "info".to_string(),
                    kernel_log_level: "warn".to_string(),
                    log_to_file: true,
                    max_log_size_mb: 10,
                },
                power: PowerConfig {
                    acpi_enabled: true,
                    power_action: "shutdown".to_string(),
                    reboot_on_panic: false,
                },
            },
            packages: vec![
                Package {
                    name: "ion".to_string(),
                    version: "1.0.0".to_string(),
                },
                Package {
                    name: "uutils".to_string(),
                    version: "0.0.1".to_string(),
                },
            ],
            drivers: Drivers {
                all: vec!["virtio-blkd".to_string(), "virtio-netd".to_string()],
                initfs: vec![],
                core: vec!["init".to_string(), "logd".to_string()],
            },
            users: BTreeMap::from([(
                "user".to_string(),
                User {
                    uid: 1000,
                    gid: 1000,
                    home: "/home/user".to_string(),
                    shell: "/bin/ion".to_string(),
                },
            )]),
            groups: BTreeMap::from([(
                "user".to_string(),
                Group {
                    gid: 1000,
                    members: vec!["user".to_string()],
                },
            )]),
            services: Services {
                init_scripts: vec!["10_net".to_string(), "15_dhcp".to_string()],
                startup_script: "/startup.sh".to_string(),
            },
            files: BTreeMap::new(),
        }
    }

    #[test]
    fn manifest_roundtrip() {
        let manifest = sample_manifest();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        let parsed: Manifest = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.system.hostname, "test-host");
        assert_eq!(parsed.packages.len(), 2);
        assert_eq!(parsed.drivers.all.len(), 2);
        assert_eq!(parsed.users.len(), 1);
    }

    #[test]
    fn manifest_version_field() {
        let manifest = sample_manifest();
        let json = serde_json::to_string(&manifest).unwrap();

        // Verify field naming matches Nix output
        assert!(json.contains("manifestVersion"));
        assert!(json.contains("redoxSystemVersion"));
        assert!(json.contains("diskSizeMB")); // explicit rename, not camelCase
    }

    #[test]
    fn manifest_empty_files() {
        let manifest = sample_manifest();
        assert!(manifest.files.is_empty());
    }

    #[test]
    fn manifest_with_files() {
        let mut manifest = sample_manifest();
        manifest.files.insert(
            "etc/passwd".to_string(),
            FileInfo {
                sha256: "abc123".to_string(),
                size: 42,
                mode: "644".to_string(),
            },
        );
        assert_eq!(manifest.files.len(), 1);
        assert_eq!(manifest.files["etc/passwd"].sha256, "abc123");
    }

    #[test]
    fn hash_file_works() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.txt");
        std::fs::write(&path, "hello world").unwrap();

        let hash = hash_file(&path).unwrap();

        // SHA256 of "hello world"
        assert_eq!(
            hash,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        );
    }

    #[test]
    fn hash_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty");
        std::fs::write(&path, "").unwrap();

        let hash = hash_file(&path).unwrap();

        // SHA256 of empty string
        assert_eq!(
            hash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn manifest_from_json() {
        let json = r#"{
            "manifestVersion": 1,
            "system": {
                "redoxSystemVersion": "0.4.0",
                "target": "x86_64-unknown-redox",
                "profile": "test",
                "hostname": "myhost",
                "timezone": "America/New_York"
            },
            "configuration": {
                "boot": { "diskSizeMB": 512, "espSizeMB": 200 },
                "hardware": {
                    "storageDrivers": ["ahcid"],
                    "networkDrivers": [],
                    "graphicsDrivers": [],
                    "audioDrivers": [],
                    "usbEnabled": false
                },
                "networking": { "enabled": false, "mode": "none", "dns": [] },
                "graphics": { "enabled": false, "resolution": "1024x768" },
                "security": {
                    "protectKernelSchemes": true,
                    "requirePasswords": false,
                    "allowRemoteRoot": false
                },
                "logging": {
                    "logLevel": "debug",
                    "kernelLogLevel": "info",
                    "logToFile": false,
                    "maxLogSizeMB": 50
                },
                "power": {
                    "acpiEnabled": true,
                    "powerAction": "hibernate",
                    "rebootOnPanic": true
                }
            },
            "packages": [{"name": "ion", "version": "1.0"}],
            "drivers": { "all": ["ahcid"], "initfs": [], "core": ["init"] },
            "users": {"root": {"uid": 0, "gid": 0, "home": "/root", "shell": "/bin/ion"}},
            "groups": {"root": {"gid": 0, "members": ["root"]}},
            "services": { "initScripts": ["00_runtime"], "startupScript": "/startup.sh" },
            "files": {}
        }"#;

        let manifest: Manifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.system.hostname, "myhost");
        assert_eq!(manifest.configuration.logging.log_level, "debug");
        assert_eq!(manifest.configuration.power.power_action, "hibernate");
        assert!(manifest.configuration.power.reboot_on_panic);
    }

    #[test]
    fn load_manifest_missing_file() {
        let result = load_manifest_from("/nonexistent/path/manifest.json");
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("manifest not found"));
    }

    #[test]
    fn load_manifest_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("manifest.json");

        let manifest = sample_manifest();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        std::fs::write(&path, json).unwrap();

        let loaded = load_manifest_from(path.to_str().unwrap()).unwrap();
        assert_eq!(loaded.system.hostname, "test-host");
        assert_eq!(loaded.packages.len(), 2);
    }

    #[test]
    fn info_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("manifest.json");

        let manifest = sample_manifest();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        std::fs::write(&path, json).unwrap();

        // Should not error
        info(Some(path.to_str().unwrap())).unwrap();
    }

    #[test]
    fn verify_with_matching_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();

        // Create a file
        let etc_dir = root.join("etc");
        std::fs::create_dir_all(&etc_dir).unwrap();
        std::fs::write(etc_dir.join("hostname"), "myhost").unwrap();

        // Hash it
        let hash = hash_file(&etc_dir.join("hostname")).unwrap();

        // Create manifest with that hash
        let mut manifest = sample_manifest();
        manifest.files.insert(
            "etc/hostname".to_string(),
            FileInfo {
                sha256: hash,
                size: 6,
                mode: "644".to_string(),
            },
        );

        // Write manifest
        let manifest_path = root.join("manifest.json");
        std::fs::write(&manifest_path, serde_json::to_string(&manifest).unwrap()).unwrap();

        // Note: verify() uses absolute paths from /, so this test only validates
        // the manifest loading path. Full verification requires running on Redox.
        let loaded = load_manifest_from(manifest_path.to_str().unwrap()).unwrap();
        assert_eq!(loaded.files.len(), 1);
    }
}
