//! System introspection and generation management for RedoxOS.
//!
//! Reads `/etc/redox-system/manifest.json` embedded at build time and
//! provides commands for querying, verifying, diffing, and managing
//! system generations.
//!
//! Commands:
//!   - `snix system info`        — display system metadata and configuration
//!   - `snix system verify`      — check all tracked files against manifest hashes
//!   - `snix system diff`        — compare current manifest with another
//!   - `snix system generations` — list all tracked system generations
//!   - `snix system switch`      — save current generation and activate a new manifest
//!   - `snix system rollback`    — revert to the previous generation

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// Default manifest path on the running Redox system
const MANIFEST_PATH: &str = "/etc/redox-system/manifest.json";

/// Directory holding generation snapshots
const GENERATIONS_DIR: &str = "/etc/redox-system/generations";

/// Marker file: which generation to activate at boot.
/// Stored alongside the generations directory on the rootfs (not in /boot/
/// which may be read-only on initfs-based systems).
const BOOT_DEFAULT_PATH: &str = "/etc/redox-system/boot-default";

// ===== Manifest Schema =====

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub manifest_version: u32,
    pub system: SystemInfo,
    #[serde(default)]
    pub generation: GenerationInfo,
    /// Boot component store paths (v2+). Missing/default for v1 manifests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub boot: Option<BootComponents>,
    pub configuration: Configuration,
    pub packages: Vec<Package>,
    pub drivers: Drivers,
    pub users: BTreeMap<String, User>,
    pub groups: BTreeMap<String, Group>,
    pub services: Services,
    #[serde(default)]
    pub files: BTreeMap<String, FileInfo>,
    #[serde(default, rename = "systemProfile")]
    pub system_profile: String,
}

/// System profile directory (managed by generation switching)
const SYSTEM_PROFILE_BIN: &str = "/nix/system/profile/bin";

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct GenerationInfo {
    /// Monotonically increasing generation number
    pub id: u32,
    /// Content hash of the rootTree (for deduplication)
    #[serde(default)]
    pub build_hash: String,
    /// Optional description (e.g. "added ripgrep", "switched to static networking")
    #[serde(default)]
    pub description: String,
    /// ISO 8601 timestamp set at switch time (not build time, for reproducibility)
    #[serde(default)]
    pub timestamp: String,
}

impl Default for GenerationInfo {
    fn default() -> Self {
        Self {
            id: 1,
            build_hash: String::new(),
            description: "initial build".to_string(),
            timestamp: String::new(),
        }
    }
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

/// Boot component store paths tracked per generation.
/// When present, generation rollback restores these files to /boot/.
/// Missing (None) for v1 manifests — activation skips boot component updates.
#[derive(Deserialize, Serialize, Debug, Clone, Default, PartialEq)]
pub struct BootComponents {
    /// Nix store path to the kernel binary (e.g. "/nix/store/abc-kernel/boot/kernel")
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kernel: Option<String>,
    /// Nix store path to the initfs image (e.g. "/nix/store/def-initfs/boot/initfs")
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initfs: Option<String>,
    /// Nix store path to the bootloader EFI binary
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bootloader: Option<String>,
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
    #[serde(default, rename = "storePath")]
    pub store_path: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Drivers {
    pub all: Vec<String>,
    pub initfs: Vec<String>,
    pub core: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone, PartialEq)]
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
    /// BLAKE3 hash of file contents (hex-encoded, 64 chars)
    pub blake3: String,
    pub size: u64,
    pub mode: String,
}

// ===== Manifest Loading =====

pub fn load_manifest_from(path: &str) -> Result<Manifest, Box<dyn std::error::Error>> {
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
    println!("  Generation: {} {}", manifest.generation.id,
        if manifest.generation.description.is_empty() { "" }
        else { &manifest.generation.description });
    if !manifest.generation.timestamp.is_empty() {
        println!("  Built:      {}", manifest.generation.timestamp);
    }
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
                if actual_hash == expected.blake3 {
                    verified += 1;
                    if verbose {
                        println!("  OK       {path}");
                    }
                } else {
                    modified += 1;
                    errors.push(format!(
                        "  CHANGED  {path}  (expected {}…, got {}…)",
                        &expected.blake3[..12],
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

    // Generation metadata
    if current.generation.id != other.generation.id {
        println!("Generation: {} -> {}", other.generation.id, current.generation.id);
        has_diff = true;
    }
    if current.generation.build_hash != other.generation.build_hash
        && !current.generation.build_hash.is_empty()
        && !other.generation.build_hash.is_empty()
    {
        println!("Build hash: {}… -> {}…",
            &other.generation.build_hash[..12.min(other.generation.build_hash.len())],
            &current.generation.build_hash[..12.min(current.generation.build_hash.len())]);
        has_diff = true;
    }

    // System metadata
    if current.system.redox_system_version != other.system.redox_system_version {
        println!("Version: {} -> {}", other.system.redox_system_version, current.system.redox_system_version);
        has_diff = true;
    }
    if current.system.profile != other.system.profile {
        println!("Profile: {} -> {}", other.system.profile, current.system.profile);
        has_diff = true;
    }
    if current.system.hostname != other.system.hostname {
        println!("Hostname: {} -> {}", other.system.hostname, current.system.hostname);
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
        .filter(|f| current.files[**f].blake3 != other.files[**f].blake3)
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

// ===== Upgrade Command =====

/// Upgrade the system from a channel: fetch → diff → install packages → activate.
///
/// This is the "NixOS-style declarative update loop" for Redox:
///   1. Update the channel (fetch latest manifest from URL)
///   2. Compare with current system manifest
///   3. Show what would change (activation plan)
///   4. Fetch new packages from the channel's binary cache
///   5. Switch to the new manifest (saves generation, activates)
///
/// If the channel has a binary cache URL, new packages are downloaded from it.
/// Otherwise, packages must already exist in the local store (e.g., from a
/// pre-staged binary cache in the rootTree).
pub fn upgrade(
    channel_name: Option<&str>,
    dry_run: bool,
    auto_yes: bool,
    manifest_path: Option<&str>,
    gen_dir: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Resolve which channel to use
    let name = match channel_name {
        Some(n) => n.to_string(),
        None => crate::channel::default_channel()?,
    };

    println!("Upgrading from channel '{name}'...");
    println!();

    // Step 1: Fetch the latest manifest from the channel URL
    if let Err(e) = crate::channel::update(&name) {
        // If network fetch fails, check if we have a cached manifest
        let cached = crate::channel::get_manifest_path(&name);
        if cached.is_err() {
            return Err(format!(
                "cannot fetch channel '{name}' and no cached manifest exists: {e}"
            ).into());
        }
        eprintln!("warning: could not update channel '{name}': {e}");
        eprintln!("         using cached manifest");
        println!();
    }

    // Step 2: Load current and new manifests
    let mpath = manifest_path.unwrap_or(MANIFEST_PATH);
    let current = load_manifest_from(mpath)?;

    let new_manifest_path = crate::channel::get_manifest_path(&name)?;
    let new_manifest = load_manifest_from(new_manifest_path.to_str().unwrap_or(""))?;

    // Step 3: Compare manifests — are they different?
    let plan = crate::activate::plan(&current, &new_manifest);

    if plan.is_empty() && current.generation.build_hash == new_manifest.generation.build_hash
        && !current.generation.build_hash.is_empty()
    {
        println!("System is already up to date (generation {}, build {}…).",
            current.generation.id,
            &current.generation.build_hash[..12.min(current.generation.build_hash.len())]);
        return Ok(());
    }

    // Step 4: Show what would change
    println!("Changes from channel '{name}':");
    println!();
    plan.display();
    println!();

    // Version info
    if current.system.redox_system_version != new_manifest.system.redox_system_version {
        println!("Version: {} → {}", current.system.redox_system_version, new_manifest.system.redox_system_version);
        println!();
    }

    if dry_run {
        println!("Dry run complete. No changes applied.");
        return Ok(());
    }

    // Step 5: Confirmation (unless --yes)
    if !auto_yes {
        // In a headless/test context, auto-accept. In interactive mode,
        // we'd prompt — but Redox doesn't have /dev/tty yet.
        // For now, proceed (tests use --yes or we auto-accept).
        eprintln!("Proceeding with upgrade (use --dry-run to preview)...");
    }

    // Step 6: Fetch new packages if needed
    let packages_fetched = fetch_upgrade_packages(&current, &new_manifest, &name)?;
    if packages_fetched > 0 {
        println!("{packages_fetched} packages installed from cache");
        println!();
    }

    // Step 7: Switch to new manifest (saves generation, activates)
    // Write the channel manifest to a temp location for switch()
    let new_json = serde_json::to_string_pretty(&new_manifest)?;
    let tmp_path = format!("/tmp/snix-upgrade-{}.json", std::process::id());
    fs::write(&tmp_path, &new_json)?;

    let desc = format!("upgrade from channel '{name}'");

    let result = switch(
        &tmp_path,
        Some(&desc),
        false,
        gen_dir,
        manifest_path,
    );

    // Clean up temp file
    let _ = fs::remove_file(&tmp_path);

    result?;

    println!();
    println!("✓ System upgraded from channel '{name}'");

    Ok(())
}

/// Fetch packages that are in the new manifest but not in the local store.
///
/// Checks the channel's binary cache (local path or URL) for each new/changed package.
/// Returns the number of packages successfully fetched.
fn fetch_upgrade_packages(
    current: &Manifest,
    new: &Manifest,
    channel_name: &str,
) -> Result<u32, Box<dyn std::error::Error>> {
    // Build set of store paths that need to be present
    let current_paths: std::collections::BTreeSet<&str> = current
        .packages
        .iter()
        .filter(|p| !p.store_path.is_empty())
        .map(|p| p.store_path.as_str())
        .collect();

    let mut needed: Vec<&Package> = Vec::new();
    for pkg in &new.packages {
        if pkg.store_path.is_empty() {
            continue;
        }
        // Skip if already in store
        if Path::new(&pkg.store_path).exists() {
            continue;
        }
        // Only fetch if this is a new or changed package
        if !current_paths.contains(pkg.store_path.as_str()) {
            needed.push(pkg);
        }
    }

    if needed.is_empty() {
        return Ok(0);
    }

    println!("Fetching {} new packages...", needed.len());

    // Try channel's binary cache URL first
    let cache_url = crate::channel::get_cache_url(channel_name);

    // Try channel's local packages index
    let packages_index_path = crate::channel::get_packages_index_path(channel_name);

    let mut fetched = 0u32;

    for pkg in &needed {
        eprintln!("  {} {}...", pkg.name, pkg.version);

        // Strategy 1: Local binary cache (e.g., /nix/cache/ or channel-local)
        if let Some(ref idx_path) = packages_index_path {
            let cache_dir = idx_path.parent().unwrap_or(Path::new("/nix/cache"));
            if let Ok(()) = crate::local_cache::fetch_local(&pkg.store_path, cache_dir.to_str().unwrap_or("/nix/cache")) {
                fetched += 1;
                continue;
            }
        }

        // Strategy 2: Embedded binary cache at /nix/cache/
        if let Ok(()) = crate::local_cache::fetch_local(&pkg.store_path, "/nix/cache") {
            fetched += 1;
            continue;
        }

        // Strategy 3: Remote binary cache URL (if configured)
        if let Some(ref url) = cache_url {
            if let Ok(()) = crate::cache::fetch(&pkg.store_path, url) {
                fetched += 1;
                continue;
            }
        }

        eprintln!("  warning: could not fetch {} — store path not available", pkg.name);
    }

    Ok(fetched)
}

// ===== Activation Command =====

/// Stand-alone activation command: show what would change between current
/// system and a target manifest, optionally applying the changes.
pub fn activate_cmd(
    target_path: &str,
    dry_run: bool,
    manifest_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mpath = manifest_path.unwrap_or(MANIFEST_PATH);
    let current = load_manifest_from(mpath)?;
    let target = load_manifest_from(target_path)?;

    let result = crate::activate::activate(&current, &target, dry_run)?;

    if !dry_run {
        // Show summary
        if !result.warnings.is_empty() {
            println!();
            println!("Warnings:");
            for w in &result.warnings {
                println!("  ⚠ {w}");
            }
        }
        if result.reboot_recommended {
            println!();
            println!("⚠ Reboot recommended: service or boot configuration changed.");
        }
    }

    Ok(())
}

// ===== Generation Management =====

/// A discovered generation on disk
#[derive(Debug)]
struct Generation {
    id: u32,
    manifest: Manifest,
    #[allow(dead_code)]
    path: std::path::PathBuf,
}

/// Scan the generations directory and return sorted generations
fn scan_generations(gen_dir: &str) -> Result<Vec<Generation>, Box<dyn std::error::Error>> {
    let dir = Path::new(gen_dir);
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut gens = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        // Generation dirs are named by number: 1/, 2/, 3/...
        if let Ok(id) = name_str.parse::<u32>() {
            let manifest_path = entry.path().join("manifest.json");
            if manifest_path.exists() {
                match load_manifest_from(manifest_path.to_str().unwrap_or("")) {
                    Ok(manifest) => {
                        gens.push(Generation {
                            id,
                            manifest,
                            path: manifest_path,
                        });
                    }
                    Err(e) => {
                        eprintln!("warning: skipping generation {id}: {e}");
                    }
                }
            }
        }
    }

    gens.sort_by_key(|g| g.id);
    Ok(gens)
}

/// Find the highest generation ID across stored generations and current manifest
fn next_generation_id(gen_dir: &str, current: &Manifest) -> u32 {
    let max_stored = scan_generations(gen_dir)
        .unwrap_or_default()
        .iter()
        .map(|g| g.id)
        .max()
        .unwrap_or(0);
    let max_id = std::cmp::max(max_stored, current.generation.id);
    max_id + 1
}

/// List all system generations
pub fn generations(gen_dir: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);
    let gens = scan_generations(dir)?;

    // Also load current system manifest
    let current = load_manifest().ok();

    if gens.is_empty() && current.is_none() {
        println!("No generations found.");
        println!("Hint: generations are created when you run 'snix system switch'.");
        return Ok(());
    }

    println!("System Generations");
    println!("==================");
    println!();
    println!("{:>4}  {:>6}  {:>4}  {:>4}  {:20}  {}",
        "Gen", "Ver", "Pkgs", "Drvs", "Timestamp", "Description");
    println!("{}", "-".repeat(72));

    for gen in &gens {
        let m = &gen.manifest;
        let is_current = current.as_ref()
            .map(|c| c.generation.id == gen.id)
            .unwrap_or(false);
        let marker = if is_current { " *" } else { "" };

        println!("{:>4}{:2}  {:>6}  {:>4}  {:>4}  {:20}  {}",
            gen.id,
            marker,
            m.system.redox_system_version,
            m.packages.len(),
            m.drivers.all.len(),
            if m.generation.timestamp.is_empty() { "-" } else { &m.generation.timestamp },
            m.generation.description,
        );
    }

    // Show current if it's not in the generations dir
    if let Some(ref cur) = current {
        let cur_in_gens = gens.iter().any(|g| g.id == cur.generation.id);
        if !cur_in_gens {
            println!("{:>4} *  {:>6}  {:>4}  {:>4}  {:20}  {} (current, not yet saved)",
                cur.generation.id,
                cur.system.redox_system_version,
                cur.packages.len(),
                cur.drivers.all.len(),
                if cur.generation.timestamp.is_empty() { "-" } else { &cur.generation.timestamp },
                cur.generation.description,
            );
        }
    }

    println!();
    if let Some(ref cur) = current {
        println!("Current generation: {}", cur.generation.id);
    }
    println!("Generations stored: {}", gens.len());

    Ok(())
}

/// Switch to a new manifest, saving the current one as a generation.
///
/// If `dry_run` is true, computes and displays the activation plan without
/// modifying anything on disk.
pub fn switch(
    new_manifest_path: &str,
    description: Option<&str>,
    dry_run: bool,
    gen_dir: Option<&str>,
    manifest_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);
    let mpath = manifest_path.unwrap_or(MANIFEST_PATH);

    // Load current manifest
    let current = load_manifest_from(mpath)?;

    // Load new manifest
    let mut new_manifest = load_manifest_from(new_manifest_path)?;

    // Assign next generation ID
    let next_id = next_generation_id(dir, &current);
    new_manifest.generation.id = next_id;
    new_manifest.generation.timestamp = current_timestamp();
    if let Some(desc) = description {
        new_manifest.generation.description = desc.to_string();
    }

    // ── Dry-run mode: show plan and exit ──
    if dry_run {
        println!("Dry run: switch to generation {next_id}");
        println!();
        crate::activate::activate(&current, &new_manifest, true)?;
        return Ok(());
    }

    // ── Save generations ──

    // Save current manifest as a generation (if not already saved)
    let current_gen_dir = Path::new(dir).join(current.generation.id.to_string());
    if !current_gen_dir.exists() {
        fs::create_dir_all(&current_gen_dir)?;
        let current_json = serde_json::to_string_pretty(&current)?;
        fs::write(current_gen_dir.join("manifest.json"), current_json)?;
        println!("Saved current system as generation {}", current.generation.id);
    }

    // Save new manifest as a generation
    let new_gen_dir = Path::new(dir).join(next_id.to_string());
    fs::create_dir_all(&new_gen_dir)?;
    let new_json = serde_json::to_string_pretty(&new_manifest)?;
    fs::write(new_gen_dir.join("manifest.json"), &new_json)?;

    // Install as current manifest
    fs::write(mpath, &new_json)?;

    // ── Activate: atomic profile swap + config file updates ──
    let activation = crate::activate::activate(&current, &new_manifest, false)?;

    // Update boot default so this generation is activated on next reboot
    if let Err(e) = write_boot_default(next_id, None) {
        eprintln!("warning: could not update boot default: {e}");
    }

    println!("Switched to generation {next_id}");

    // Show brief package diff
    let cur_pkgs: std::collections::BTreeSet<_> = current.packages.iter()
        .map(|p| &p.name).collect();
    let new_pkgs: std::collections::BTreeSet<_> = new_manifest.packages.iter()
        .map(|p| &p.name).collect();
    let added: Vec<_> = new_pkgs.difference(&cur_pkgs).collect();
    let removed: Vec<_> = cur_pkgs.difference(&new_pkgs).collect();

    if !added.is_empty() || !removed.is_empty() {
        println!();
        if !added.is_empty() {
            println!("Packages added:   {}", added.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
        }
        if !removed.is_empty() {
            println!("Packages removed: {}", removed.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
        }
    }

    if current.system.redox_system_version != new_manifest.system.redox_system_version {
        println!("Version: {} -> {}", current.system.redox_system_version, new_manifest.system.redox_system_version);
    }

    // Show activation warnings
    if !activation.warnings.is_empty() {
        println!();
        println!("Warnings:");
        for w in &activation.warnings {
            println!("  ⚠ {w}");
        }
    }

    if activation.reboot_recommended {
        println!();
        println!("⚠ Reboot recommended: service or boot configuration changed.");
    }

    Ok(())
}

/// Rollback to the previous generation (or a specific one)
pub fn rollback(
    target_id: Option<u32>,
    gen_dir: Option<&str>,
    manifest_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);
    let mpath = manifest_path.unwrap_or(MANIFEST_PATH);

    let current = load_manifest_from(mpath)?;
    let gens = scan_generations(dir)?;

    if gens.is_empty() {
        return Err("No previous generations found. Nothing to roll back to.".into());
    }

    // Find target generation
    let target = match target_id {
        Some(id) => {
            gens.iter().find(|g| g.id == id)
                .ok_or_else(|| format!("Generation {id} not found. Available: {}",
                    gens.iter().map(|g| g.id.to_string()).collect::<Vec<_>>().join(", ")))?
        }
        None => {
            // Find the most recent generation BEFORE the current one
            gens.iter()
                .rev()
                .find(|g| g.id < current.generation.id)
                .or_else(|| gens.last()) // fallback to latest stored
                .ok_or("No previous generation found to roll back to.")?
        }
    };

    if target.id == current.generation.id {
        println!("Already at generation {}. Nothing to do.", target.id);
        return Ok(());
    }

    println!("Rolling back from generation {} to generation {}...",
        current.generation.id, target.id);
    println!();

    // Show what changes
    let cur_pkgs: std::collections::BTreeSet<_> = current.packages.iter()
        .map(|p| &p.name).collect();
    let tgt_pkgs: std::collections::BTreeSet<_> = target.manifest.packages.iter()
        .map(|p| &p.name).collect();
    let added: Vec<_> = tgt_pkgs.difference(&cur_pkgs).collect();
    let removed: Vec<_> = cur_pkgs.difference(&tgt_pkgs).collect();

    if !added.is_empty() {
        println!("Packages restored: {}", added.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
    }
    if !removed.is_empty() {
        println!("Packages removed:  {}", removed.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
    }

    if current.system.redox_system_version != target.manifest.system.redox_system_version {
        println!("Version: {} -> {}", current.system.redox_system_version, target.manifest.system.redox_system_version);
    }

    // Save current as a generation if not already saved
    let current_gen_dir = Path::new(dir).join(current.generation.id.to_string());
    if !current_gen_dir.exists() {
        fs::create_dir_all(&current_gen_dir)?;
        let current_json = serde_json::to_string_pretty(&current)?;
        fs::write(current_gen_dir.join("manifest.json"), current_json)?;
    }

    // Write the target manifest as current (update generation metadata)
    let mut rolled_back = target.manifest.clone();
    let next_id = next_generation_id(dir, &current);
    rolled_back.generation.id = next_id;
    rolled_back.generation.timestamp = current_timestamp();
    rolled_back.generation.description = format!("rollback to generation {}", target.id);

    // Save rolled-back state as new generation
    let new_gen_dir = Path::new(dir).join(next_id.to_string());
    fs::create_dir_all(&new_gen_dir)?;
    let new_json = serde_json::to_string_pretty(&rolled_back)?;
    fs::write(new_gen_dir.join("manifest.json"), &new_json)?;

    // Install as current
    fs::write(mpath, &new_json)?;

    // ── Activate: atomic profile swap + config file updates ──
    let activation = crate::activate::activate(&current, &rolled_back, false)?;

    // Update boot default so this generation is activated on next reboot
    if let Err(e) = write_boot_default(next_id, None) {
        eprintln!("warning: could not update boot default: {e}");
    }

    println!();
    println!("Rolled back to generation {} (saved as generation {next_id})", target.id);

    if activation.binaries_linked > 0 {
        println!("Profile rebuilt: {} binaries linked", activation.binaries_linked);
    }

    // Show activation warnings
    if !activation.warnings.is_empty() {
        println!();
        println!("Warnings:");
        for w in &activation.warnings {
            println!("  ⚠ {w}");
        }
    }

    if activation.reboot_recommended {
        println!();
        println!("⚠ Reboot recommended: service or boot configuration changed.");
    }

    println!();
    println!("Note: Boot-essential binaries in /bin/ are unchanged.");
    println!("Profile binaries in /nix/system/profile/bin/ have been updated.");

    Ok(())
}

// ===== Boot Generation Selection =====

/// Activate a stored generation without creating a new generation entry.
///
/// Used by the `85_generation_select` init script at boot time.
/// Loads the generation's manifest, runs activate() to rebuild the profile
/// and write config files, then updates the current manifest on disk.
/// Does NOT create a new generation (unlike rollback).
pub fn activate_boot(
    generation_id: u32,
    gen_dir: Option<&str>,
    manifest_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);
    let mpath = manifest_path.unwrap_or(MANIFEST_PATH);

    let current = load_manifest_from(mpath)?;

    // Skip if already at the requested generation
    if current.generation.id == generation_id {
        eprintln!("boot: already at generation {generation_id}, skipping activation");
        return Ok(());
    }

    let gens = scan_generations(dir)?;
    let target = gens
        .iter()
        .find(|g| g.id == generation_id)
        .ok_or_else(|| {
            format!(
                "generation {generation_id} not found (available: {})",
                gens.iter()
                    .map(|g| g.id.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;

    eprintln!(
        "boot: activating generation {} ({})",
        target.id, target.manifest.generation.description
    );

    // Activate: rebuild profile + write config files
    let activation = crate::activate::activate(&current, &target.manifest, false)?;

    // Update the on-disk manifest to match the activated generation
    let json = serde_json::to_string_pretty(&target.manifest)?;
    fs::write(mpath, &json)?;

    if activation.binaries_linked > 0 {
        eprintln!(
            "boot: profile rebuilt ({} binaries linked)",
            activation.binaries_linked
        );
    }

    if !activation.warnings.is_empty() {
        for w in &activation.warnings {
            eprintln!("boot: warning: {w}");
        }
    }

    Ok(())
}

/// Read the boot default generation ID from the marker file.
pub fn read_boot_default(
    boot_default_path: Option<&str>,
) -> Result<Option<u32>, Box<dyn std::error::Error>> {
    let path = boot_default_path.unwrap_or(BOOT_DEFAULT_PATH);
    if !Path::new(path).exists() {
        return Ok(None);
    }
    let content = fs::read_to_string(path)?.trim().to_string();
    if content.is_empty() {
        return Ok(None);
    }
    let id: u32 = content
        .parse()
        .map_err(|e| format!("invalid generation ID in {path}: {e}"))?;
    Ok(Some(id))
}

/// Write the boot default generation marker.
pub fn write_boot_default(
    generation_id: u32,
    boot_default_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let path = boot_default_path.unwrap_or(BOOT_DEFAULT_PATH);
    // Ensure /boot/ directory exists
    if let Some(parent) = Path::new(path).parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, format!("{generation_id}\n"))?;
    Ok(())
}

/// `snix system boot [N]` — show or set the next-boot generation.
pub fn boot_cmd(
    generation_id: Option<u32>,
    gen_dir: Option<&str>,
    boot_default_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);

    match generation_id {
        Some(id) => {
            // Verify the generation exists
            let gens = scan_generations(dir)?;
            if !gens.iter().any(|g| g.id == id) {
                return Err(format!(
                    "generation {id} not found (available: {})",
                    gens.iter()
                        .map(|g| g.id.to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
                .into());
            }

            write_boot_default(id, boot_default_path)?;
            println!("Next boot will activate generation {id}");
            println!("(Run `snix system rollback --generation {id}` to activate it now)");
        }
        None => {
            // Show current boot default
            match read_boot_default(boot_default_path)? {
                Some(id) => {
                    println!("Boot default: generation {id}");
                }
                None => {
                    println!("No boot default set (system boots with current manifest)");
                }
            }
        }
    }

    Ok(())
}

/// Rebuild the system profile by re-symlinking package binaries from /nix/store/.
/// This is what makes generation switching actually change which binaries are in PATH.
fn rebuild_system_profile(manifest: &Manifest) -> Result<(), Box<dyn std::error::Error>> {
    let profile_bin = Path::new(SYSTEM_PROFILE_BIN);

    // Ensure directory is writable (Nix store outputs have mode 555)
    if profile_bin.exists() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o755);
            fs::set_permissions(profile_bin, perms)?;
        }

        // Clear existing profile symlinks
        for entry in fs::read_dir(profile_bin)? {
            let entry = entry?;
            if entry.path().symlink_metadata()?.file_type().is_symlink() {
                fs::remove_file(entry.path())?;
            }
        }
    } else {
        fs::create_dir_all(profile_bin)?;
    }

    // Recreate symlinks from store paths listed in the manifest
    let mut linked = 0u32;
    for pkg in &manifest.packages {
        if pkg.store_path.is_empty() {
            continue;
        }
        let bin_dir = Path::new(&pkg.store_path).join("bin");
        if !bin_dir.exists() {
            eprintln!("warning: store path missing for {}: {}", pkg.name, pkg.store_path);
            continue;
        }
        for entry in fs::read_dir(&bin_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let name = entry.file_name();
            let link_path = profile_bin.join(&name);
            let target = entry.path();

            if link_path.symlink_metadata().is_ok() {
                fs::remove_file(&link_path)?;
            }

            #[cfg(unix)]
            std::os::unix::fs::symlink(&target, &link_path)?;
            #[cfg(not(unix))]
            fs::copy(&target, &link_path)?;

            linked += 1;
        }
    }

    println!("System profile rebuilt: {linked} binaries linked");
    Ok(())
}

/// Update GC roots to protect a generation's store paths from garbage collection.
///
/// Creates `gen-{N}-{pkg}` roots for the given manifest's generation. Does NOT
/// remove other generations' roots — each generation stays rooted until explicitly
/// deleted via `delete_generations()`. This matches the NixOS model where every
/// profile generation is a GC root until the user removes it.
///
/// On first call after upgrade from the old `system-*` naming, migrates all
/// existing generations to the new naming scheme.
fn update_system_gc_roots(manifest: &Manifest, gen_dir: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let gc_roots = crate::store::GcRoots::open()?;
    update_system_gc_roots_with(&gc_roots, manifest, gen_dir)
}

/// Inner implementation that accepts a GcRoots instance (testable).
fn update_system_gc_roots_with(
    gc_roots: &crate::store::GcRoots,
    manifest: &Manifest,
    gen_dir: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);

    // Migration: if old system-* roots exist, re-root all existing generations
    migrate_gc_roots_if_needed(gc_roots, dir)?;

    // Add roots for this generation's packages
    let gen_id = manifest.generation.id;
    let added = add_generation_gc_roots(gc_roots, gen_id, &manifest.packages)?;

    // Add roots for boot component store paths
    let boot_added = add_boot_gc_roots(gc_roots, gen_id, &manifest.boot)?;

    let total = added + boot_added;
    if total > 0 {
        println!("GC roots updated: {added} packages + {boot_added} boot components protected for generation {gen_id}");
    }

    Ok(())
}

/// Add GC roots for a single generation's packages.
/// Returns the number of roots successfully added.
fn add_generation_gc_roots(
    gc_roots: &crate::store::GcRoots,
    gen_id: u32,
    packages: &[Package],
) -> Result<u32, Box<dyn std::error::Error>> {
    let mut added = 0u32;
    for pkg in packages {
        if !pkg.store_path.is_empty() {
            let root_name = format!("gen-{}-{}", gen_id, pkg.name);
            if let Err(e) = gc_roots.add_root(&root_name, &pkg.store_path) {
                eprintln!("warning: could not add GC root for gen-{}-{}: {e}", gen_id, pkg.name);
            } else {
                added += 1;
            }
        }
    }
    Ok(added)
}

/// Add GC roots for a generation's boot component store paths.
/// Boot paths use the `gen-{N}-boot-{component}` naming convention.
fn add_boot_gc_roots(
    gc_roots: &crate::store::GcRoots,
    gen_id: u32,
    boot: &Option<BootComponents>,
) -> Result<u32, Box<dyn std::error::Error>> {
    let boot = match boot {
        Some(b) => b,
        None => return Ok(0),
    };
    let mut added = 0u32;
    // Extract the store path directory from the full file path.
    // e.g. "/nix/store/abc-kernel/boot/kernel" → "/nix/store/abc-kernel"
    let extract_store_dir = |path: &str| -> Option<String> {
        if let Some(rest) = path.strip_prefix("/nix/store/") {
            // Find the first '/' after the hash-name
            if let Some(idx) = rest.find('/') {
                return Some(format!("/nix/store/{}", &rest[..idx]));
            }
        }
        // Fallback: use the path as-is (may be a direct store path)
        Some(path.to_string())
    };
    for (name, path_opt) in [
        ("boot-kernel", &boot.kernel),
        ("boot-initfs", &boot.initfs),
        ("boot-bootloader", &boot.bootloader),
    ] {
        if let Some(ref path) = path_opt {
            if let Some(store_dir) = extract_store_dir(path) {
                let root_name = format!("gen-{}-{}", gen_id, name);
                if let Err(e) = gc_roots.add_root(&root_name, &store_dir) {
                    eprintln!("warning: could not add GC root for {root_name}: {e}");
                } else {
                    added += 1;
                }
            }
        }
    }
    Ok(added)
}

/// Remove all GC roots for a specific generation.
fn remove_generation_gc_roots(
    gc_roots: &crate::store::GcRoots,
    gen_id: u32,
) -> Result<u32, Box<dyn std::error::Error>> {
    let prefix = format!("gen-{}-", gen_id);
    let mut removed = 0u32;
    if let Ok(roots) = gc_roots.list_roots() {
        for root in roots {
            if root.name.starts_with(&prefix) {
                let _ = gc_roots.remove_root(&root.name);
                removed += 1;
            }
        }
    }
    Ok(removed)
}

/// Migrate from old `system-*` GC root naming to per-generation `gen-{N}-*` naming.
/// Scans all existing generations and creates roots for each. Then removes old roots.
/// No-op if no `system-*` roots exist.
fn migrate_gc_roots_if_needed(
    gc_roots: &crate::store::GcRoots,
    gen_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let roots = gc_roots.list_roots()?;
    let old_roots: Vec<_> = roots.iter()
        .filter(|r| r.name.starts_with("system-"))
        .collect();

    if old_roots.is_empty() {
        return Ok(());
    }

    eprintln!("Migrating {} old system-* GC roots to per-generation naming...", old_roots.len());

    // Root all existing generations
    let gens = scan_generations(gen_dir)?;
    let mut total_added = 0u32;
    for gen in &gens {
        let added = add_generation_gc_roots(gc_roots, gen.id, &gen.manifest.packages)?;
        total_added += added;
    }

    // Remove old system-* roots
    for root in &old_roots {
        let _ = gc_roots.remove_root(&root.name);
    }

    eprintln!("Migration complete: {total_added} roots created for {} generations, {} old roots removed",
        gens.len(), old_roots.len());

    Ok(())
}

// ===== Generation Deletion =====

/// Selector for which generations to delete.
#[derive(Debug, PartialEq)]
enum GenerationSelector {
    /// Delete specific generation IDs: `1 3 5`
    Ids(Vec<u32>),
    /// Keep the last N generations: `+N`
    KeepLast(u32),
    /// Delete generations older than N days: `Nd`
    OlderThanDays(u32),
    /// Delete all except current (and boot-default): `old`
    Old,
}

/// Parse a generation selector string.
///
/// Formats:
/// - `old` — all except current
/// - `+N` — keep last N
/// - `Nd` — older than N days
/// - `1 3 5` — specific IDs
fn parse_generation_selector(input: &str) -> Result<GenerationSelector, Box<dyn std::error::Error>> {
    let trimmed = input.trim();

    if trimmed == "old" {
        return Ok(GenerationSelector::Old);
    }

    if let Some(n) = trimmed.strip_prefix('+') {
        let count: u32 = n.parse()
            .map_err(|_| format!("invalid keep count: +{n}"))?;
        if count == 0 {
            return Err("keep count must be at least 1".into());
        }
        return Ok(GenerationSelector::KeepLast(count));
    }

    if let Some(n) = trimmed.strip_suffix('d') {
        let days: u32 = n.parse()
            .map_err(|_| format!("invalid day count: {n}d"))?;
        return Ok(GenerationSelector::OlderThanDays(days));
    }

    // Try parsing as space-separated IDs
    let ids: Result<Vec<u32>, _> = trimmed.split_whitespace()
        .map(|s| s.parse::<u32>())
        .collect();
    match ids {
        Ok(ids) if !ids.is_empty() => Ok(GenerationSelector::Ids(ids)),
        _ => Err(format!("invalid selector: {trimmed}. Use 'old', '+N', 'Nd', or space-separated IDs.").into()),
    }
}

/// Statistics from a generation deletion.
#[derive(Debug, Default)]
pub struct DeleteGenerationsStats {
    /// Number of generations deleted.
    pub generations_deleted: u32,
    /// Number of GC roots removed.
    pub roots_removed: u32,
    /// IDs of generations that were deleted.
    pub deleted_ids: Vec<u32>,
    /// IDs of generations that were protected (current/boot-default).
    pub protected_ids: Vec<u32>,
}

/// Delete generations matching the selector.
///
/// Protected generations (current + boot-default) are never deleted.
/// Removes generation directories and their `gen-{N}-*` GC roots.
/// Does NOT run store GC — call `store::run_gc()` separately.
pub fn delete_generations(
    selector: &str,
    dry_run: bool,
    gen_dir: Option<&str>,
    manifest_path: Option<&str>,
    boot_default_path: Option<&str>,
) -> Result<DeleteGenerationsStats, Box<dyn std::error::Error>> {
    let gc_roots = crate::store::GcRoots::open()?;
    delete_generations_with(
        &gc_roots, selector, dry_run, gen_dir, manifest_path, boot_default_path,
    )
}

/// Inner implementation that accepts a GcRoots instance (testable).
fn delete_generations_with(
    gc_roots: &crate::store::GcRoots,
    selector: &str,
    dry_run: bool,
    gen_dir: Option<&str>,
    manifest_path: Option<&str>,
    boot_default_path: Option<&str>,
) -> Result<DeleteGenerationsStats, Box<dyn std::error::Error>> {
    let dir = gen_dir.unwrap_or(GENERATIONS_DIR);
    let mpath = manifest_path.unwrap_or(MANIFEST_PATH);

    let current = load_manifest_from(mpath)?;
    let current_id = current.generation.id;

    let boot_default_id = read_boot_default(boot_default_path)?;

    let gens = scan_generations(dir)?;
    let parsed = parse_generation_selector(selector)?;

    // Build protected set
    let mut protected = std::collections::BTreeSet::new();
    protected.insert(current_id);
    if let Some(bd) = boot_default_id {
        protected.insert(bd);
    }

    // Determine which generations to delete
    let to_delete: Vec<u32> = match parsed {
        GenerationSelector::Ids(ref ids) => {
            ids.iter().filter(|id| !protected.contains(id)).copied().collect()
        }
        GenerationSelector::KeepLast(n) => {
            // Keep the N most recent (by ID), delete the rest
            let mut sorted_ids: Vec<u32> = gens.iter().map(|g| g.id).collect();
            sorted_ids.sort();
            let keep_count = n as usize;
            if sorted_ids.len() > keep_count {
                let delete_count = sorted_ids.len() - keep_count;
                sorted_ids[..delete_count].iter()
                    .filter(|id| !protected.contains(id))
                    .copied()
                    .collect()
            } else {
                Vec::new()
            }
        }
        GenerationSelector::OlderThanDays(days) => {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let cutoff = now.saturating_sub(days as u64 * 86400);

            gens.iter()
                .filter(|g| {
                    if protected.contains(&g.id) {
                        return false;
                    }
                    // Parse timestamp to epoch seconds
                    let gen_epoch = parse_timestamp_to_epoch(&g.manifest.generation.timestamp);
                    gen_epoch < cutoff
                })
                .map(|g| g.id)
                .collect()
        }
        GenerationSelector::Old => {
            gens.iter()
                .map(|g| g.id)
                .filter(|id| !protected.contains(id))
                .collect()
        }
    };

    // Check if user tried to delete a protected generation
    let mut stats = DeleteGenerationsStats::default();
    if let GenerationSelector::Ids(ref ids) = parsed {
        for id in ids {
            if protected.contains(id) {
                stats.protected_ids.push(*id);
                if *id == current_id {
                    eprintln!("Skipping generation {id}: current generation (cannot delete)");
                } else {
                    eprintln!("Skipping generation {id}: boot-default generation (cannot delete)");
                }
            }
        }
    }

    if to_delete.is_empty() {
        println!("Nothing to delete.");
        return Ok(stats);
    }

    for id in &to_delete {
        let gen_path = Path::new(dir).join(id.to_string());

        if dry_run {
            println!("would delete: generation {id} ({})", gen_path.display());
        } else {
            // Remove GC roots first
            let roots_removed = remove_generation_gc_roots(gc_roots, *id)?;
            stats.roots_removed += roots_removed;

            // Remove generation directory
            if gen_path.exists() {
                fs::remove_dir_all(&gen_path)?;
            }
        }

        stats.generations_deleted += 1;
        stats.deleted_ids.push(*id);
    }

    if dry_run {
        println!();
        println!("Would delete {} generations.", stats.generations_deleted);
    } else {
        println!("Deleted {} generations ({} GC roots removed).",
            stats.generations_deleted, stats.roots_removed);
    }

    Ok(stats)
}

/// Parse an ISO 8601 timestamp to epoch seconds. Returns 0 on parse failure.
fn parse_timestamp_to_epoch(ts: &str) -> u64 {
    // Format: "2026-02-19T10:00:00Z"
    if ts.len() < 19 {
        return 0;
    }
    let parts: Vec<&str> = ts.split('T').collect();
    if parts.len() != 2 {
        return 0;
    }
    let date_parts: Vec<&str> = parts[0].split('-').collect();
    let time_str = parts[1].trim_end_matches('Z');
    let time_parts: Vec<&str> = time_str.split(':').collect();

    if date_parts.len() != 3 || time_parts.len() != 3 {
        return 0;
    }

    let year: u64 = date_parts[0].parse().unwrap_or(0);
    let month: u64 = date_parts[1].parse().unwrap_or(0);
    let day: u64 = date_parts[2].parse().unwrap_or(0);
    let hour: u64 = time_parts[0].parse().unwrap_or(0);
    let minute: u64 = time_parts[1].parse().unwrap_or(0);
    let second: u64 = time_parts[2].parse().unwrap_or(0);

    // Approximate: days since epoch
    // Good enough for "older than N days" comparisons
    let mut total_days: u64 = 0;
    for y in 1970..year {
        total_days += if is_leap_year(y) { 366 } else { 365 };
    }
    let days_in_month = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for m in 1..month {
        total_days += days_in_month[m as usize] as u64;
        if m == 2 && is_leap_year(year) {
            total_days += 1;
        }
    }
    total_days += day - 1;

    total_days * 86400 + hour * 3600 + minute * 60 + second
}

fn is_leap_year(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

// ===== System GC (convenience wrapper) =====

/// Combined generation pruning and store GC.
///
/// 1. Prune generations (delete-generations with `+N` or `old`)
/// 2. Run store GC to sweep unreferenced paths
pub fn system_gc(
    keep: Option<u32>,
    dry_run: bool,
    gen_dir: Option<&str>,
    manifest_path: Option<&str>,
    boot_default_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Step 1: Prune generations
    let selector = match keep {
        Some(n) => format!("+{n}"),
        None => "old".to_string(),
    };

    println!("── Pruning generations ──");
    let stats = delete_generations(&selector, dry_run, gen_dir, manifest_path, boot_default_path)?;

    // Step 2: Store GC
    println!();
    println!("── Store garbage collection ──");
    crate::store::run_gc(dry_run)?;

    if !dry_run && stats.generations_deleted > 0 {
        println!();
        println!("Summary: {} generations pruned, store swept.",
            stats.generations_deleted);
    }

    Ok(())
}

/// Public accessor for current_timestamp (used by channel module).
pub fn current_timestamp_pub() -> String {
    current_timestamp()
}

/// Public accessor for update_system_gc_roots (used by activate module).
pub fn update_system_gc_roots_pub(manifest: &Manifest, gen_dir: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    update_system_gc_roots(manifest, gen_dir)
}

/// Get current timestamp as ISO 8601 string
/// On Redox, this reads the system clock. Falls back gracefully.
fn current_timestamp() -> String {
    // Try to read /scheme/time/now or use a simple epoch-based approach
    // For portability, use a basic approach that works on both Linux and Redox
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => {
            let secs = d.as_secs();
            // Simple UTC timestamp without pulling in chrono
            let days = secs / 86400;
            let remaining = secs % 86400;
            let hours = remaining / 3600;
            let minutes = (remaining % 3600) / 60;
            let seconds = remaining % 60;

            // Days since 1970-01-01 → approximate date
            // Good enough for generation tracking
            let (year, month, day) = days_to_date(days);
            format!("{year:04}-{month:02}-{day:02}T{hours:02}:{minutes:02}:{seconds:02}Z")
        }
        Err(_) => String::new(),
    }
}

/// Convert days since epoch to (year, month, day)
fn days_to_date(days: u64) -> (u64, u64, u64) {
    // Civil days algorithm (Howard Hinnant)
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ===== Helpers =====

fn hash_file(path: &Path) -> std::io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; 16384]; // Larger buffer — BLAKE3 thrives on bulk
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
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
            generation: GenerationInfo {
                id: 1,
                build_hash: "abc123".to_string(),
                description: "initial build".to_string(),
                timestamp: "2026-02-19T10:00:00Z".to_string(),
            },
            boot: None,
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
                    store_path: String::new(),
                },
                Package {
                    name: "uutils".to_string(),
                    version: "0.0.1".to_string(),
                    store_path: String::new(),
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
            system_profile: String::new(),
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
                blake3: "abc123".to_string(),
                size: 42,
                mode: "644".to_string(),
            },
        );
        assert_eq!(manifest.files.len(), 1);
        assert_eq!(manifest.files["etc/passwd"].blake3, "abc123");
    }

    #[test]
    fn hash_file_works() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.txt");
        std::fs::write(&path, "hello world").unwrap();

        let hash = hash_file(&path).unwrap();

        // BLAKE3 of "hello world"
        assert_eq!(
            hash,
            "d74981efa70a0c880b8d8c1985d075dbcbf679b99a5f9914e5aaf96b831a9e24"
        );
    }

    #[test]
    fn hash_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty");
        std::fs::write(&path, "").unwrap();

        let hash = hash_file(&path).unwrap();

        // BLAKE3 of empty input
        assert_eq!(
            hash,
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
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
                blake3: hash,
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

    // ===== Generation Tests =====

    #[test]
    fn generation_default_values() {
        let gen = GenerationInfo::default();
        assert_eq!(gen.id, 1);
        assert_eq!(gen.description, "initial build");
        assert!(gen.build_hash.is_empty());
        assert!(gen.timestamp.is_empty());
    }

    #[test]
    fn manifest_generation_field_serializes() {
        let manifest = sample_manifest();
        let json = serde_json::to_string(&manifest).unwrap();
        assert!(json.contains("\"generation\""));
        assert!(json.contains("\"buildHash\""));
        assert!(json.contains("\"description\""));
        assert!(json.contains("initial build"));
    }

    #[test]
    fn manifest_generation_deserializes() {
        let json = r#"{
            "manifestVersion": 1,
            "system": {
                "redoxSystemVersion": "0.4.0",
                "target": "x86_64-unknown-redox",
                "profile": "test",
                "hostname": "myhost",
                "timezone": "UTC"
            },
            "generation": {
                "id": 3,
                "buildHash": "deadbeef",
                "description": "added ripgrep",
                "timestamp": "2026-02-19T12:00:00Z"
            },
            "configuration": {
                "boot": { "diskSizeMB": 512, "espSizeMB": 200 },
                "hardware": {
                    "storageDrivers": [], "networkDrivers": [],
                    "graphicsDrivers": [], "audioDrivers": [], "usbEnabled": false
                },
                "networking": { "enabled": false, "mode": "none", "dns": [] },
                "graphics": { "enabled": false, "resolution": "1024x768" },
                "security": { "protectKernelSchemes": true, "requirePasswords": false, "allowRemoteRoot": false },
                "logging": { "logLevel": "info", "kernelLogLevel": "warn", "logToFile": true, "maxLogSizeMB": 10 },
                "power": { "acpiEnabled": true, "powerAction": "shutdown", "rebootOnPanic": false }
            },
            "packages": [],
            "drivers": { "all": [], "initfs": [], "core": [] },
            "users": {},
            "groups": {},
            "services": { "initScripts": [], "startupScript": "/startup.sh" },
            "files": {}
        }"#;

        let manifest: Manifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.generation.id, 3);
        assert_eq!(manifest.generation.build_hash, "deadbeef");
        assert_eq!(manifest.generation.description, "added ripgrep");
        assert_eq!(manifest.generation.timestamp, "2026-02-19T12:00:00Z");
    }

    #[test]
    fn manifest_without_generation_uses_defaults() {
        // Old manifests won't have the generation field — should use Default
        let json = r#"{
            "manifestVersion": 1,
            "system": {
                "redoxSystemVersion": "0.3.0",
                "target": "x86_64-unknown-redox",
                "profile": "test",
                "hostname": "old-host",
                "timezone": "UTC"
            },
            "configuration": {
                "boot": { "diskSizeMB": 512, "espSizeMB": 200 },
                "hardware": {
                    "storageDrivers": [], "networkDrivers": [],
                    "graphicsDrivers": [], "audioDrivers": [], "usbEnabled": false
                },
                "networking": { "enabled": false, "mode": "none", "dns": [] },
                "graphics": { "enabled": false, "resolution": "1024x768" },
                "security": { "protectKernelSchemes": true, "requirePasswords": false, "allowRemoteRoot": false },
                "logging": { "logLevel": "info", "kernelLogLevel": "warn", "logToFile": true, "maxLogSizeMB": 10 },
                "power": { "acpiEnabled": true, "powerAction": "shutdown", "rebootOnPanic": false }
            },
            "packages": [],
            "drivers": { "all": [], "initfs": [], "core": [] },
            "users": {},
            "groups": {},
            "services": { "initScripts": [], "startupScript": "/startup.sh" },
            "files": {}
        }"#;

        let manifest: Manifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.generation.id, 1);
        assert_eq!(manifest.generation.description, "initial build");
    }

    #[test]
    fn scan_generations_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        let gens = scan_generations(dir.path().to_str().unwrap()).unwrap();
        assert!(gens.is_empty());
    }

    #[test]
    fn scan_generations_nonexistent_dir() {
        let gens = scan_generations("/nonexistent/path").unwrap();
        assert!(gens.is_empty());
    }

    #[test]
    fn scan_generations_finds_numbered_dirs() {
        let dir = tempfile::tempdir().unwrap();

        // Create 3 generations
        for i in 1..=3 {
            let gen_dir = dir.path().join(i.to_string());
            std::fs::create_dir_all(&gen_dir).unwrap();
            let mut m = sample_manifest();
            m.generation.id = i;
            m.generation.description = format!("gen {i}");
            let json = serde_json::to_string_pretty(&m).unwrap();
            std::fs::write(gen_dir.join("manifest.json"), json).unwrap();
        }

        let gens = scan_generations(dir.path().to_str().unwrap()).unwrap();
        assert_eq!(gens.len(), 3);
        assert_eq!(gens[0].id, 1);
        assert_eq!(gens[1].id, 2);
        assert_eq!(gens[2].id, 3);
        assert_eq!(gens[0].manifest.generation.description, "gen 1");
    }

    #[test]
    fn scan_generations_skips_non_numeric_dirs() {
        let dir = tempfile::tempdir().unwrap();

        // Valid generation
        let gen1 = dir.path().join("1");
        std::fs::create_dir_all(&gen1).unwrap();
        let m = sample_manifest();
        std::fs::write(gen1.join("manifest.json"), serde_json::to_string(&m).unwrap()).unwrap();

        // Non-numeric dir — should be skipped
        let invalid = dir.path().join("latest");
        std::fs::create_dir_all(&invalid).unwrap();
        std::fs::write(invalid.join("manifest.json"), "{}").unwrap();

        let gens = scan_generations(dir.path().to_str().unwrap()).unwrap();
        assert_eq!(gens.len(), 1);
        assert_eq!(gens[0].id, 1);
    }

    #[test]
    fn next_generation_id_increments() {
        let dir = tempfile::tempdir().unwrap();

        let m = sample_manifest(); // generation.id = 1
        assert_eq!(next_generation_id(dir.path().to_str().unwrap(), &m), 2);

        // Add generation 5
        let gen5 = dir.path().join("5");
        std::fs::create_dir_all(&gen5).unwrap();
        let mut m5 = sample_manifest();
        m5.generation.id = 5;
        std::fs::write(gen5.join("manifest.json"), serde_json::to_string(&m5).unwrap()).unwrap();

        assert_eq!(next_generation_id(dir.path().to_str().unwrap(), &m), 6);
    }

    #[test]
    fn switch_creates_generations() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");
        let new_manifest_file = dir.path().join("new.json");

        // Write current manifest
        let mut current = sample_manifest();
        current.generation.id = 1;
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&current).unwrap()).unwrap();

        // Write new manifest (with different packages)
        let mut new_m = sample_manifest();
        new_m.packages.push(Package { name: "ripgrep".to_string(), version: "14.0".to_string(), store_path: String::new() });
        std::fs::write(&new_manifest_file, serde_json::to_string_pretty(&new_m).unwrap()).unwrap();

        // Switch
        switch(
            new_manifest_file.to_str().unwrap(),
            Some("added ripgrep"),
            false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify generation 1 was saved
        assert!(gen_dir.join("1/manifest.json").exists());

        // Verify generation 2 was created
        assert!(gen_dir.join("2/manifest.json").exists());

        // Verify current manifest was updated
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.generation.id, 2);
        assert_eq!(active.generation.description, "added ripgrep");
        assert_eq!(active.packages.len(), 3); // ion + uutils + ripgrep
        assert!(!active.generation.timestamp.is_empty());
    }

    #[test]
    fn rollback_restores_previous() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");

        // Create generation 1
        let gen1_dir = gen_dir.join("1");
        std::fs::create_dir_all(&gen1_dir).unwrap();
        let mut gen1 = sample_manifest();
        gen1.generation.id = 1;
        gen1.generation.description = "first".to_string();
        std::fs::write(gen1_dir.join("manifest.json"), serde_json::to_string_pretty(&gen1).unwrap()).unwrap();

        // Create generation 2 (current)
        let gen2_dir = gen_dir.join("2");
        std::fs::create_dir_all(&gen2_dir).unwrap();
        let mut gen2 = sample_manifest();
        gen2.generation.id = 2;
        gen2.generation.description = "added extra package".to_string();
        gen2.packages.push(Package { name: "ripgrep".to_string(), version: "14.0".to_string(), store_path: String::new() });
        std::fs::write(gen2_dir.join("manifest.json"), serde_json::to_string_pretty(&gen2).unwrap()).unwrap();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&gen2).unwrap()).unwrap();

        // Rollback to generation 1
        rollback(
            Some(1),
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify current manifest has gen1's packages but new generation ID
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.packages.len(), 2); // Back to ion + uutils only
        assert_eq!(active.generation.id, 3); // New generation (3 = rollback)
        assert!(active.generation.description.contains("rollback to generation 1"));
    }

    #[test]
    fn rollback_no_generations_errors() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("empty_gens");
        let manifest_file = dir.path().join("current.json");

        std::fs::create_dir_all(&gen_dir).unwrap();
        let m = sample_manifest();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&m).unwrap()).unwrap();

        let result = rollback(
            None,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_err());
    }

    #[test]
    fn days_to_date_epoch() {
        let (y, m, d) = days_to_date(0);
        assert_eq!((y, m, d), (1970, 1, 1));
    }

    #[test]
    fn days_to_date_known_date() {
        // 2026-02-19 is day 20503 since epoch
        let (y, m, d) = days_to_date(20503);
        assert_eq!((y, m, d), (2026, 2, 19));
    }

    #[test]
    fn current_timestamp_format() {
        let ts = current_timestamp();
        // Should be ISO 8601 format or empty
        if !ts.is_empty() {
            assert!(ts.contains('T'));
            assert!(ts.ends_with('Z'));
            assert!(ts.len() >= 19); // YYYY-MM-DDTHH:MM:SSZ
        }
    }

    #[test]
    fn generations_with_stored_gens() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");

        // Create 2 generations
        for i in 1..=2 {
            let gd = gen_dir.join(i.to_string());
            std::fs::create_dir_all(&gd).unwrap();
            let mut m = sample_manifest();
            m.generation.id = i;
            std::fs::write(gd.join("manifest.json"), serde_json::to_string(&m).unwrap()).unwrap();
        }

        // Should not error (just prints to stdout)
        generations(Some(gen_dir.to_str().unwrap())).unwrap();
    }

    // ===== Comprehensive Generation Switching Tests =====

    #[test]
    fn package_with_storepath_roundtrip() {
        let pkg = Package {
            name: "test".to_string(),
            version: "1.0".to_string(),
            store_path: "/nix/store/abc123-test".to_string(),
        };

        let json = serde_json::to_string(&pkg).unwrap();
        let parsed: Package = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.name, "test");
        assert_eq!(parsed.version, "1.0");
        assert_eq!(parsed.store_path, "/nix/store/abc123-test");
    }

    #[test]
    fn package_without_storepath_deserializes() {
        let json = r#"{"name":"x","version":"1"}"#;
        let pkg: Package = serde_json::from_str(json).unwrap();

        assert_eq!(pkg.name, "x");
        assert_eq!(pkg.version, "1");
        assert_eq!(pkg.store_path, "");
    }

    #[test]
    fn manifest_systemprofile_roundtrip() {
        let mut manifest = sample_manifest();
        manifest.system_profile = "/nix/store/xyz789-system-profile".to_string();

        let json = serde_json::to_string_pretty(&manifest).unwrap();
        let parsed: Manifest = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.system_profile, "/nix/store/xyz789-system-profile");
    }

    #[test]
    fn manifest_without_systemprofile_defaults() {
        // Old manifest JSON without systemProfile field
        let json = r#"{
            "manifestVersion": 1,
            "system": {
                "redoxSystemVersion": "0.4.0",
                "target": "x86_64-unknown-redox",
                "profile": "test",
                "hostname": "old-host",
                "timezone": "UTC"
            },
            "configuration": {
                "boot": { "diskSizeMB": 512, "espSizeMB": 200 },
                "hardware": {
                    "storageDrivers": [], "networkDrivers": [],
                    "graphicsDrivers": [], "audioDrivers": [], "usbEnabled": false
                },
                "networking": { "enabled": false, "mode": "none", "dns": [] },
                "graphics": { "enabled": false, "resolution": "1024x768" },
                "security": { "protectKernelSchemes": true, "requirePasswords": false, "allowRemoteRoot": false },
                "logging": { "logLevel": "info", "kernelLogLevel": "warn", "logToFile": true, "maxLogSizeMB": 10 },
                "power": { "acpiEnabled": true, "powerAction": "shutdown", "rebootOnPanic": false }
            },
            "packages": [],
            "drivers": { "all": [], "initfs": [], "core": [] },
            "users": {},
            "groups": {},
            "services": { "initScripts": [], "startupScript": "/startup.sh" },
            "files": {}
        }"#;

        let manifest: Manifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.system_profile, "");
    }

    #[test]
    fn switch_increments_generation_id() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");
        let new_manifest_file = dir.path().join("new.json");

        // Set up gen 1 in generations dir
        let gen1_dir = gen_dir.join("1");
        std::fs::create_dir_all(&gen1_dir).unwrap();
        let mut gen1 = sample_manifest();
        gen1.generation.id = 1;
        std::fs::write(gen1_dir.join("manifest.json"), serde_json::to_string_pretty(&gen1).unwrap()).unwrap();

        // Current manifest is gen 1
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&gen1).unwrap()).unwrap();

        // Create new manifest
        let mut new_m = sample_manifest();
        new_m.packages.push(Package {
            name: "newpkg".to_string(),
            version: "1.0".to_string(),
            store_path: String::new(),
        });
        std::fs::write(&new_manifest_file, serde_json::to_string_pretty(&new_m).unwrap()).unwrap();

        // Switch
        switch(
            new_manifest_file.to_str().unwrap(),
            Some("test switch"),
            false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify current manifest has gen id 2
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.generation.id, 2);
    }

    #[test]
    fn switch_saves_old_generation() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");
        let new_manifest_file = dir.path().join("new.json");

        // Current manifest is gen 1
        let mut current = sample_manifest();
        current.generation.id = 1;
        current.generation.description = "original".to_string();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&current).unwrap()).unwrap();

        // New manifest
        let new_m = sample_manifest();
        std::fs::write(&new_manifest_file, serde_json::to_string_pretty(&new_m).unwrap()).unwrap();

        // Switch
        switch(
            new_manifest_file.to_str().unwrap(),
            Some("new gen"),
            false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify generations/1/manifest.json exists with old content
        let saved_path = gen_dir.join("1/manifest.json");
        assert!(saved_path.exists());

        let saved = load_manifest_from(saved_path.to_str().unwrap()).unwrap();
        assert_eq!(saved.generation.id, 1);
        assert_eq!(saved.generation.description, "original");
    }

    #[test]
    fn switch_preserves_storepath() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");
        let new_manifest_file = dir.path().join("new.json");

        // Current manifest
        let current = sample_manifest();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&current).unwrap()).unwrap();

        // New manifest with store_path
        let mut new_m = sample_manifest();
        new_m.packages.push(Package {
            name: "helix".to_string(),
            version: "24.07".to_string(),
            store_path: "/nix/store/abc123-helix-24.07".to_string(),
        });
        std::fs::write(&new_manifest_file, serde_json::to_string_pretty(&new_m).unwrap()).unwrap();

        // Switch
        switch(
            new_manifest_file.to_str().unwrap(),
            Some("test"),
            false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify the switched manifest preserves store_path
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        let helix_pkg = active.packages.iter().find(|p| p.name == "helix").unwrap();
        assert_eq!(helix_pkg.store_path, "/nix/store/abc123-helix-24.07");
    }

    #[test]
    fn rollback_increments_id() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");

        // Create generation 1
        let gen1_dir = gen_dir.join("1");
        std::fs::create_dir_all(&gen1_dir).unwrap();
        let mut gen1 = sample_manifest();
        gen1.generation.id = 1;
        gen1.generation.description = "first".to_string();
        std::fs::write(gen1_dir.join("manifest.json"), serde_json::to_string_pretty(&gen1).unwrap()).unwrap();

        // Create generation 2 (current)
        let gen2_dir = gen_dir.join("2");
        std::fs::create_dir_all(&gen2_dir).unwrap();
        let mut gen2 = sample_manifest();
        gen2.generation.id = 2;
        gen2.generation.description = "second".to_string();
        std::fs::write(gen2_dir.join("manifest.json"), serde_json::to_string_pretty(&gen2).unwrap()).unwrap();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&gen2).unwrap()).unwrap();

        // Rollback to gen 1
        rollback(
            Some(1),
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify current manifest has gen id 3 (new gen, not reuse of 1)
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.generation.id, 3);
        assert!(active.generation.description.contains("rollback"));
        assert!(active.generation.description.contains("1"));
    }

    #[test]
    fn rollback_same_id_noop() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");

        // Create generation 2 (current)
        let gen2_dir = gen_dir.join("2");
        std::fs::create_dir_all(&gen2_dir).unwrap();
        let mut gen2 = sample_manifest();
        gen2.generation.id = 2;
        std::fs::write(gen2_dir.join("manifest.json"), serde_json::to_string_pretty(&gen2).unwrap()).unwrap();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&gen2).unwrap()).unwrap();

        // Try to rollback to the same generation
        let result = rollback(
            Some(2),
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );

        // Should succeed with "Already at generation" message (no error)
        assert!(result.is_ok());

        // Verify no new generation was created
        assert!(!gen_dir.join("3").exists());

        // Verify manifest unchanged
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.generation.id, 2);
    }

    #[test]
    fn scan_generations_sorted() {
        let dir = tempfile::tempdir().unwrap();

        // Create generations in random order: 3, 1, 5, 2
        for id in [3, 1, 5, 2] {
            let gen_dir = dir.path().join(id.to_string());
            std::fs::create_dir_all(&gen_dir).unwrap();
            let mut m = sample_manifest();
            m.generation.id = id;
            std::fs::write(gen_dir.join("manifest.json"), serde_json::to_string(&m).unwrap()).unwrap();
        }

        let gens = scan_generations(dir.path().to_str().unwrap()).unwrap();

        assert_eq!(gens.len(), 4);
        assert_eq!(gens[0].id, 1);
        assert_eq!(gens[1].id, 2);
        assert_eq!(gens[2].id, 3);
        assert_eq!(gens[3].id, 5);
    }

    #[test]
    fn next_generation_id_with_gaps() {
        let dir = tempfile::tempdir().unwrap();

        // Create gens 1, 2, 7 (with gaps)
        for id in [1, 2, 7] {
            let gen_dir = dir.path().join(id.to_string());
            std::fs::create_dir_all(&gen_dir).unwrap();
            let mut m = sample_manifest();
            m.generation.id = id;
            std::fs::write(gen_dir.join("manifest.json"), serde_json::to_string(&m).unwrap()).unwrap();
        }

        // Current manifest has gen id 5
        let mut current = sample_manifest();
        current.generation.id = 5;

        // Should return 8 (max of stored=7, current=5, then +1)
        let next = next_generation_id(dir.path().to_str().unwrap(), &current);
        assert_eq!(next, 8);
    }

    #[test]
    fn manifest_extra_field_ignored() {
        // Add an unknown field to manifest JSON
        let json = r#"{
            "manifestVersion": 1,
            "unknownField": "should be ignored",
            "system": {
                "redoxSystemVersion": "0.4.0",
                "target": "x86_64-unknown-redox",
                "profile": "test",
                "hostname": "myhost",
                "timezone": "UTC"
            },
            "configuration": {
                "boot": { "diskSizeMB": 512, "espSizeMB": 200 },
                "hardware": {
                    "storageDrivers": [], "networkDrivers": [],
                    "graphicsDrivers": [], "audioDrivers": [], "usbEnabled": false
                },
                "networking": { "enabled": false, "mode": "none", "dns": [] },
                "graphics": { "enabled": false, "resolution": "1024x768" },
                "security": { "protectKernelSchemes": true, "requirePasswords": false, "allowRemoteRoot": false },
                "logging": { "logLevel": "info", "kernelLogLevel": "warn", "logToFile": true, "maxLogSizeMB": 10 },
                "power": { "acpiEnabled": true, "powerAction": "shutdown", "rebootOnPanic": false }
            },
            "packages": [],
            "drivers": { "all": [], "initfs": [], "core": [] },
            "users": {},
            "groups": {},
            "services": { "initScripts": [], "startupScript": "/startup.sh" },
            "files": {}
        }"#;

        // Should deserialize successfully, ignoring the unknown field
        let result = serde_json::from_str::<Manifest>(json);
        assert!(result.is_ok());

        let manifest = result.unwrap();
        assert_eq!(manifest.system.hostname, "myhost");
    }

    #[test]
    fn switch_with_gc_roots_resilient() {
        // Verify switch succeeds even when GC root directory isn't writable
        // (update_system_gc_roots errors are non-fatal warnings)
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");
        let new_manifest_file = dir.path().join("new.json");

        let current = sample_manifest();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&current).unwrap()).unwrap();

        let mut new_m = sample_manifest();
        new_m.packages[0].store_path =
            "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-1.0".to_string();
        std::fs::write(
            &new_manifest_file,
            serde_json::to_string_pretty(&new_m).unwrap(),
        )
        .unwrap();

        // switch() calls update_system_gc_roots which tries /nix/var/snix/gcroots/
        // On the host this may fail — but switch should still succeed (errors are warnings)
        let result = switch(
            new_manifest_file.to_str().unwrap(),
            Some("test gc"),
            false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_ok());

        // Verify manifest was still updated
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.packages[0].store_path, "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-1.0");
    }

    #[test]
    fn rollback_with_gc_roots_resilient() {
        // Verify rollback succeeds even when GC root updates fail
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");

        // Create generation 1
        let gen1_dir = gen_dir.join("1");
        std::fs::create_dir_all(&gen1_dir).unwrap();
        let mut gen1 = sample_manifest();
        gen1.generation.id = 1;
        gen1.packages[0].store_path =
            "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-1.0".to_string();
        std::fs::write(
            gen1_dir.join("manifest.json"),
            serde_json::to_string_pretty(&gen1).unwrap(),
        )
        .unwrap();

        // Current is gen 2
        let gen2_dir = gen_dir.join("2");
        std::fs::create_dir_all(&gen2_dir).unwrap();
        let mut gen2 = sample_manifest();
        gen2.generation.id = 2;
        std::fs::write(
            gen2_dir.join("manifest.json"),
            serde_json::to_string_pretty(&gen2).unwrap(),
        )
        .unwrap();
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&gen2).unwrap()).unwrap();

        let result = rollback(
            Some(1),
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_ok());
    }

    // ===== Dry-run Switch Tests =====

    #[test]
    fn switch_dry_run_does_not_modify() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("current.json");
        let new_manifest_file = dir.path().join("new.json");

        // Current manifest
        let mut current = sample_manifest();
        current.generation.id = 1;
        std::fs::write(&manifest_file, serde_json::to_string_pretty(&current).unwrap()).unwrap();

        // New manifest with extra package
        let mut new_m = sample_manifest();
        new_m.packages.push(Package {
            name: "ripgrep".to_string(),
            version: "14.0".to_string(),
            store_path: String::new(),
        });
        std::fs::write(&new_manifest_file, serde_json::to_string_pretty(&new_m).unwrap()).unwrap();

        // Dry-run switch
        switch(
            new_manifest_file.to_str().unwrap(),
            Some("dry run test"),
            true, // dry_run = true
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        ).unwrap();

        // Verify NOTHING was modified:
        // - No generations directory created
        assert!(!gen_dir.exists());

        // - Current manifest unchanged (still gen 1, 2 packages)
        let active = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(active.generation.id, 1);
        assert_eq!(active.packages.len(), 2);
    }

    // ===== Upgrade Tests =====

    #[test]
    fn upgrade_plan_detects_no_changes() {
        let m = sample_manifest();
        let plan = crate::activate::plan(&m, &m);
        assert!(plan.is_empty());
    }

    #[test]
    fn upgrade_plan_detects_package_additions() {
        let current = sample_manifest();
        let mut new_m = sample_manifest();
        new_m.packages.push(Package {
            name: "ripgrep".to_string(),
            version: "14.0".to_string(),
            store_path: "/nix/store/abc-ripgrep-14.0".to_string(),
        });

        let plan = crate::activate::plan(&current, &new_m);
        assert!(!plan.is_empty());
        assert_eq!(plan.packages_added, vec!["ripgrep"]);
        assert!(plan.profile_needs_rebuild);
    }

    #[test]
    fn upgrade_plan_detects_version_change() {
        let current = sample_manifest();
        let mut new_m = sample_manifest();
        new_m.system.redox_system_version = "0.5.0".to_string();
        new_m.packages[0].version = "2.0.0".to_string();
        new_m.packages[0].store_path = "/nix/store/new-ion-2.0.0".to_string();

        let plan = crate::activate::plan(&current, &new_m);
        assert!(!plan.is_empty());
        assert_eq!(plan.packages_changed.len(), 1);
        assert_eq!(plan.packages_changed[0].name, "ion");
    }

    #[test]
    fn upgrade_same_build_hash_is_up_to_date() {
        let mut current = sample_manifest();
        current.generation.build_hash = "deadbeef12345678".to_string();

        let mut new_m = sample_manifest();
        new_m.generation.build_hash = "deadbeef12345678".to_string();

        let plan = crate::activate::plan(&current, &new_m);
        // Plan is empty AND build hashes match → up to date
        assert!(plan.is_empty());
        assert_eq!(current.generation.build_hash, new_m.generation.build_hash);
    }

    #[test]
    fn upgrade_different_build_hash_needs_update() {
        let mut current = sample_manifest();
        current.generation.build_hash = "aaaaaa".to_string();

        let mut new_m = sample_manifest();
        new_m.generation.build_hash = "bbbbbb".to_string();

        // Even if packages are identical, different build hash means a rebuild happened
        let _plan = crate::activate::plan(&current, &new_m);
        // Plan itself may be empty (same packages), but build hash differs
        assert_ne!(current.generation.build_hash, new_m.generation.build_hash);
    }

    #[test]
    fn upgrade_preserves_store_paths() {
        let current = sample_manifest();
        let mut new_m = sample_manifest();
        new_m.packages.push(Package {
            name: "helix".to_string(),
            version: "24.07".to_string(),
            store_path: "/nix/store/xyz-helix-24.07".to_string(),
        });

        let plan = crate::activate::plan(&current, &new_m);
        assert_eq!(plan.packages_added, vec!["helix"]);

        // The new manifest preserves all store paths
        let helix = new_m.packages.iter().find(|p| p.name == "helix").unwrap();
        assert_eq!(helix.store_path, "/nix/store/xyz-helix-24.07");
    }

    #[test]
    fn upgrade_detects_config_and_service_changes() {
        let mut current = sample_manifest();
        current.files.insert("etc/passwd".to_string(), FileInfo {
            blake3: "aaa111".to_string(), size: 42, mode: "644".to_string(),
        });
        let mut new_m = current.clone();
        // Add a new service
        new_m.services.init_scripts.push("20_httpd".to_string());
        // Change a config file hash
        new_m.files.get_mut("etc/passwd").unwrap().blake3 = "changed123".to_string();
        // Add a new config file
        new_m.files.insert("etc/httpd.conf".to_string(), FileInfo {
            blake3: "newfile".to_string(),
            size: 50,
            mode: "644".to_string(),
        });

        let plan = crate::activate::plan(&current, &new_m);
        assert_eq!(plan.services_added, vec!["20_httpd"]);
        assert_eq!(plan.config_files_added, vec!["etc/httpd.conf"]);
        assert_eq!(plan.config_files_changed.len(), 1);
        assert_eq!(plan.config_files_changed[0].path, "etc/passwd");
    }

    #[test]
    fn activate_cmd_dry_run() {
        let dir = tempfile::tempdir().unwrap();
        let current_file = dir.path().join("current.json");
        let target_file = dir.path().join("target.json");

        let current = sample_manifest();
        let mut target = sample_manifest();
        target.packages.push(Package {
            name: "fd".to_string(),
            version: "9.0".to_string(),
            store_path: String::new(),
        });

        std::fs::write(&current_file, serde_json::to_string_pretty(&current).unwrap()).unwrap();
        std::fs::write(&target_file, serde_json::to_string_pretty(&target).unwrap()).unwrap();

        // Should succeed (dry-run, just displays plan)
        let result = activate_cmd(
            target_file.to_str().unwrap(),
            true,
            Some(current_file.to_str().unwrap()),
        );
        assert!(result.is_ok());
    }

    // ===== Boot Generation Selection Tests =====

    #[test]
    fn activate_boot_valid_generation() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("manifest.json");

        // Write current manifest (gen 1)
        let mut manifest = sample_manifest();
        manifest.generation.id = 1;
        manifest.system.hostname = "original".to_string();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        fs::write(&manifest_file, &json).unwrap();

        // Create generation 2 with a different hostname
        let gen2_dir = gen_dir.join("2");
        fs::create_dir_all(&gen2_dir).unwrap();
        let mut gen2_manifest = sample_manifest();
        gen2_manifest.generation.id = 2;
        gen2_manifest.system.hostname = "gen2-host".to_string();
        gen2_manifest.generation.description = "hostname change".to_string();
        let gen2_json = serde_json::to_string_pretty(&gen2_manifest).unwrap();
        fs::write(gen2_dir.join("manifest.json"), &gen2_json).unwrap();

        // Activate generation 2
        let result = activate_boot(
            2,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_ok(), "activate_boot failed: {:?}", result.err());

        // Verify manifest was updated
        let updated = load_manifest_from(manifest_file.to_str().unwrap()).unwrap();
        assert_eq!(updated.system.hostname, "gen2-host");
        assert_eq!(updated.generation.id, 2);
    }

    #[test]
    fn activate_boot_missing_generation() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        fs::create_dir_all(&gen_dir).unwrap();
        let manifest_file = dir.path().join("manifest.json");

        let manifest = sample_manifest();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        fs::write(&manifest_file, &json).unwrap();

        let result = activate_boot(
            99,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn activate_boot_skips_current_generation() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        fs::create_dir_all(&gen_dir).unwrap();
        let manifest_file = dir.path().join("manifest.json");

        let mut manifest = sample_manifest();
        manifest.generation.id = 3;
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        fs::write(&manifest_file, &json).unwrap();

        // Activating the same generation we're already at should succeed (no-op)
        let result = activate_boot(
            3,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_ok());
    }

    #[test]
    fn activate_boot_corrupt_manifest() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let manifest_file = dir.path().join("manifest.json");

        let manifest = sample_manifest();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        fs::write(&manifest_file, &json).unwrap();

        // Create generation 2 with invalid JSON
        let gen2_dir = gen_dir.join("2");
        fs::create_dir_all(&gen2_dir).unwrap();
        fs::write(gen2_dir.join("manifest.json"), "not valid json {{{").unwrap();

        // scan_generations skips corrupt manifests, so gen 2 won't be found
        let result = activate_boot(
            2,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not found"));
    }

    #[test]
    fn read_write_boot_default() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("default-generation");

        // No file yet
        assert_eq!(read_boot_default(Some(marker.to_str().unwrap())).unwrap(), None);

        // Write
        write_boot_default(5, Some(marker.to_str().unwrap())).unwrap();

        // Read back
        assert_eq!(read_boot_default(Some(marker.to_str().unwrap())).unwrap(), Some(5));
    }

    #[test]
    fn read_boot_default_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("default-generation");
        fs::write(&marker, "").unwrap();

        assert_eq!(read_boot_default(Some(marker.to_str().unwrap())).unwrap(), None);
    }

    #[test]
    fn read_boot_default_invalid_content() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("default-generation");
        fs::write(&marker, "not-a-number\n").unwrap();

        let result = read_boot_default(Some(marker.to_str().unwrap()));
        assert!(result.is_err());
    }

    #[test]
    fn boot_cmd_set_and_show() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        let marker = dir.path().join("default-generation");

        // Create generation 3
        let gen3_dir = gen_dir.join("3");
        fs::create_dir_all(&gen3_dir).unwrap();
        let manifest = sample_manifest();
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        fs::write(gen3_dir.join("manifest.json"), &json).unwrap();

        // Set boot default
        let result = boot_cmd(
            Some(3),
            Some(gen_dir.to_str().unwrap()),
            Some(marker.to_str().unwrap()),
        );
        assert!(result.is_ok());
        assert_eq!(read_boot_default(Some(marker.to_str().unwrap())).unwrap(), Some(3));

        // Show boot default (no generation arg)
        let result = boot_cmd(
            None,
            Some(gen_dir.to_str().unwrap()),
            Some(marker.to_str().unwrap()),
        );
        assert!(result.is_ok());
    }

    #[test]
    fn boot_cmd_nonexistent_generation() {
        let dir = tempfile::tempdir().unwrap();
        let gen_dir = dir.path().join("generations");
        fs::create_dir_all(&gen_dir).unwrap();
        let marker = dir.path().join("default-generation");

        let result = boot_cmd(
            Some(99),
            Some(gen_dir.to_str().unwrap()),
            Some(marker.to_str().unwrap()),
        );
        assert!(result.is_err());
    }

    // ===== Per-Generation GC Root Tests =====

    fn make_gc_roots(tmp: &tempfile::TempDir) -> crate::store::GcRoots {
        crate::store::GcRoots::open_at(tmp.path().join("gcroots")).unwrap()
    }

    fn root_names(gc_roots: &crate::store::GcRoots) -> Vec<String> {
        gc_roots.list_roots().unwrap().into_iter().map(|r| r.name).collect()
    }

    // Valid nixbase32 store paths for GC root tests
    const SP_ION_V1: &str = "/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-1.0";
    const SP_ION_V2: &str = "/nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-ion-2.0";
    const SP_UUTILS: &str = "/nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-uutils-1.0";
    const SP_RIPGREP: &str = "/nix/store/4f6mybrlblj9lmpz5hzfs0l9f7q4sp7s-ripgrep-14.0";

    #[test]
    fn add_generation_gc_roots_creates_named_roots() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        let pkgs = vec![
            Package { name: "ion".into(), version: "1.0".into(), store_path: SP_ION_V1.into() },
            Package { name: "uutils".into(), version: "1.0".into(), store_path: SP_UUTILS.into() },
        ];

        let added = add_generation_gc_roots(&gc_roots, 3, &pkgs).unwrap();
        assert_eq!(added, 2);

        let names = root_names(&gc_roots);
        assert!(names.contains(&"gen-3-ion".to_string()));
        assert!(names.contains(&"gen-3-uutils".to_string()));
    }

    #[test]
    fn add_generation_gc_roots_skips_empty_store_path() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        let pkgs = vec![
            Package { name: "ion".into(), version: "1.0".into(), store_path: SP_ION_V1.into() },
            Package { name: "empty".into(), version: "1.0".into(), store_path: String::new() },
        ];

        let added = add_generation_gc_roots(&gc_roots, 1, &pkgs).unwrap();
        assert_eq!(added, 1);

        let names = root_names(&gc_roots);
        assert_eq!(names.len(), 1);
        assert!(names.contains(&"gen-1-ion".to_string()));
    }

    #[test]
    fn remove_generation_gc_roots_removes_only_target() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        // Add roots for gen 1 and gen 2
        gc_roots.add_root("gen-1-ion", SP_ION_V1).unwrap();
        gc_roots.add_root("gen-1-uutils", SP_UUTILS).unwrap();
        gc_roots.add_root("gen-2-ion", SP_ION_V2).unwrap();
        gc_roots.add_root("gen-2-ripgrep", SP_RIPGREP).unwrap();

        // Remove gen 1 roots only
        let removed = remove_generation_gc_roots(&gc_roots, 1).unwrap();
        assert_eq!(removed, 2);

        let names = root_names(&gc_roots);
        assert_eq!(names.len(), 2);
        assert!(names.contains(&"gen-2-ion".to_string()));
        assert!(names.contains(&"gen-2-ripgrep".to_string()));
    }

    #[test]
    fn remove_generation_gc_roots_nonexistent_is_noop() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        gc_roots.add_root("gen-1-ion", SP_ION_V1).unwrap();

        let removed = remove_generation_gc_roots(&gc_roots, 99).unwrap();
        assert_eq!(removed, 0);
        assert_eq!(root_names(&gc_roots).len(), 1);
    }

    #[test]
    fn old_gen_roots_survive_new_gen_rooting() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);
        let gen_dir = tmp.path().join("generations");
        fs::create_dir_all(&gen_dir).unwrap();

        // Simulate gen 1 already rooted
        gc_roots.add_root("gen-1-ion", SP_ION_V1).unwrap();
        gc_roots.add_root("gen-1-uutils", SP_UUTILS).unwrap();

        // Root gen 2 (as update_system_gc_roots would)
        let mut m2 = sample_manifest();
        m2.generation.id = 2;
        m2.packages[0].store_path = SP_ION_V2.into();
        m2.packages[1].store_path = SP_UUTILS.into();
        m2.packages.push(Package { name: "ripgrep".into(), version: "14.0".into(), store_path: SP_RIPGREP.into() });

        // update_system_gc_roots should NOT remove gen-1 roots
        update_system_gc_roots_with(&gc_roots, &m2, Some(gen_dir.to_str().unwrap())).unwrap();

        let names = root_names(&gc_roots);
        // gen-1 roots preserved
        assert!(names.contains(&"gen-1-ion".to_string()));
        assert!(names.contains(&"gen-1-uutils".to_string()));
        // gen-2 roots added
        assert!(names.contains(&"gen-2-ion".to_string()));
        assert!(names.contains(&"gen-2-uutils".to_string()));
        assert!(names.contains(&"gen-2-ripgrep".to_string()));
        assert_eq!(names.len(), 5);
    }

    #[test]
    fn migration_converts_system_roots_to_gen_roots() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);
        let gen_dir = tmp.path().join("generations");

        // Create 2 existing generations
        for id in 1..=2 {
            let gd = gen_dir.join(id.to_string());
            fs::create_dir_all(&gd).unwrap();
            let mut m = sample_manifest();
            m.generation.id = id;
            m.packages[0].store_path = if id == 1 { SP_ION_V1.into() } else { SP_ION_V2.into() };
            m.packages[1].store_path = SP_UUTILS.into();
            fs::write(gd.join("manifest.json"), serde_json::to_string(&m).unwrap()).unwrap();
        }

        // Old-style system-* roots
        gc_roots.add_root("system-ion", SP_ION_V2).unwrap();
        gc_roots.add_root("system-uutils", SP_UUTILS).unwrap();

        // Trigger migration via update_system_gc_roots for gen 3
        let mut m3 = sample_manifest();
        m3.generation.id = 3;
        m3.packages[0].store_path = SP_ION_V2.into();
        m3.packages[1].store_path = SP_UUTILS.into();
        m3.packages.push(Package { name: "ripgrep".into(), version: "14.0".into(), store_path: SP_RIPGREP.into() });

        update_system_gc_roots_with(&gc_roots, &m3, Some(gen_dir.to_str().unwrap())).unwrap();

        let names = root_names(&gc_roots);
        // Old system-* roots gone
        assert!(!names.iter().any(|n| n.starts_with("system-")));
        // Gen 1, 2, 3 roots all exist
        assert!(names.contains(&"gen-1-ion".to_string()));
        assert!(names.contains(&"gen-1-uutils".to_string()));
        assert!(names.contains(&"gen-2-ion".to_string()));
        assert!(names.contains(&"gen-2-uutils".to_string()));
        assert!(names.contains(&"gen-3-ion".to_string()));
        assert!(names.contains(&"gen-3-uutils".to_string()));
        assert!(names.contains(&"gen-3-ripgrep".to_string()));
    }

    #[test]
    fn migration_noop_when_no_system_roots() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);
        let gen_dir = tmp.path().join("generations");
        fs::create_dir_all(&gen_dir).unwrap();

        // Already have gen-style roots (no system-* roots)
        gc_roots.add_root("gen-1-ion", SP_ION_V1).unwrap();

        // update_system_gc_roots should skip migration
        let mut m2 = sample_manifest();
        m2.generation.id = 2;
        m2.packages[0].store_path = SP_ION_V2.into();
        m2.packages[1].store_path = SP_UUTILS.into();

        update_system_gc_roots_with(&gc_roots, &m2, Some(gen_dir.to_str().unwrap())).unwrap();

        let names = root_names(&gc_roots);
        // gen-1 root still there
        assert!(names.contains(&"gen-1-ion".to_string()));
        // gen-2 roots added
        assert!(names.contains(&"gen-2-ion".to_string()));
        assert!(names.contains(&"gen-2-uutils".to_string()));
    }

    // ===== Boot Component GC Root Tests =====

    const SP_KERNEL: &str = "/nix/store/5g8nzclclk9lnqz6izgsml0a8r5aq8ss-kernel";
    const SP_INITFS: &str = "/nix/store/6h9padmfmla0prz7jzharn1f9s6ar9ss-initfs";
    const SP_KERNEL2: &str = "/nix/store/7j0qbfvngn0g1qsz8kaiasq2g0a7vs0v-kernel2";

    #[test]
    fn boot_gc_roots_added_for_generation() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        let boot = Some(BootComponents {
            kernel: Some(format!("{SP_KERNEL}/boot/kernel")),
            initfs: Some(format!("{SP_INITFS}/boot/initfs")),
            bootloader: None,
        });

        let added = add_boot_gc_roots(&gc_roots, 1, &boot).unwrap();
        assert_eq!(added, 2);

        let names = root_names(&gc_roots);
        assert!(names.contains(&"gen-1-boot-kernel".to_string()));
        assert!(names.contains(&"gen-1-boot-initfs".to_string()));
    }

    #[test]
    fn boot_gc_roots_none_is_noop() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        let added = add_boot_gc_roots(&gc_roots, 1, &None).unwrap();
        assert_eq!(added, 0);
        assert!(root_names(&gc_roots).is_empty());
    }

    #[test]
    fn boot_gc_roots_removed_with_generation() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        // Add package + boot roots for gen 1
        gc_roots.add_root("gen-1-ion", SP_ION_V1).unwrap();
        gc_roots.add_root("gen-1-boot-kernel", SP_KERNEL).unwrap();
        gc_roots.add_root("gen-1-boot-initfs", SP_INITFS).unwrap();
        // And gen 2
        gc_roots.add_root("gen-2-ion", SP_ION_V2).unwrap();
        gc_roots.add_root("gen-2-boot-kernel", SP_KERNEL).unwrap();

        // Remove gen 1 — both package and boot roots go
        let removed = remove_generation_gc_roots(&gc_roots, 1).unwrap();
        assert_eq!(removed, 3); // ion + boot-kernel + boot-initfs

        let names = root_names(&gc_roots);
        assert_eq!(names.len(), 2);
        assert!(names.contains(&"gen-2-ion".to_string()));
        assert!(names.contains(&"gen-2-boot-kernel".to_string()));
    }

    #[test]
    fn shared_boot_paths_kept_until_last_generation() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);

        // Gen 1 and gen 2 share the same kernel store path
        gc_roots.add_root("gen-1-boot-kernel", SP_KERNEL).unwrap();
        gc_roots.add_root("gen-2-boot-kernel", SP_KERNEL).unwrap();
        // Gen 3 has a different kernel
        gc_roots.add_root("gen-3-boot-kernel", SP_KERNEL2).unwrap();

        // Delete gen 1 — shared kernel still rooted by gen 2
        remove_generation_gc_roots(&gc_roots, 1).unwrap();
        let names = root_names(&gc_roots);
        assert!(names.contains(&"gen-2-boot-kernel".to_string()));

        // Delete gen 2 — now the old kernel has no roots
        remove_generation_gc_roots(&gc_roots, 2).unwrap();
        let names = root_names(&gc_roots);
        assert_eq!(names.len(), 1);
        assert!(names.contains(&"gen-3-boot-kernel".to_string()));
    }

    #[test]
    fn update_gc_roots_includes_boot_components() {
        let tmp = tempfile::tempdir().unwrap();
        let gc_roots = make_gc_roots(&tmp);
        let gen_dir = tmp.path().join("generations");
        fs::create_dir_all(&gen_dir).unwrap();

        let mut m = sample_manifest();
        m.generation.id = 1;
        // Use valid nixbase32 store paths for packages
        m.packages = vec![
            Package { name: "ion".into(), version: "1.0".into(), store_path: SP_ION_V1.into() },
            Package { name: "uutils".into(), version: "1.0".into(), store_path: SP_UUTILS.into() },
        ];
        m.boot = Some(BootComponents {
            kernel: Some(format!("{SP_KERNEL}/boot/kernel")),
            initfs: Some(format!("{SP_INITFS}/boot/initfs")),
            bootloader: None,
        });

        update_system_gc_roots_with(&gc_roots, &m, Some(gen_dir.to_str().unwrap())).unwrap();

        let names = root_names(&gc_roots);
        // Package roots
        assert!(names.contains(&"gen-1-ion".to_string()));
        assert!(names.contains(&"gen-1-uutils".to_string()));
        // Boot roots
        assert!(names.contains(&"gen-1-boot-kernel".to_string()));
        assert!(names.contains(&"gen-1-boot-initfs".to_string()));
        assert_eq!(names.len(), 4);
    }

    // ===== Delete Generations Tests =====

    /// Set up N generations in a tempdir with GC roots. Returns (gen_dir, manifest_file, gc_roots, boot_default_path).
    fn setup_generations(
        tmp: &tempfile::TempDir,
        count: u32,
        current_id: u32,
    ) -> (std::path::PathBuf, std::path::PathBuf, crate::store::GcRoots, std::path::PathBuf) {
        let gen_dir = tmp.path().join("generations");
        let manifest_file = tmp.path().join("manifest.json");
        let boot_default_path = tmp.path().join("boot-default");
        let gc_roots = make_gc_roots(tmp);

        for id in 1..=count {
            let gd = gen_dir.join(id.to_string());
            fs::create_dir_all(&gd).unwrap();
            let mut m = sample_manifest();
            m.generation.id = id;
            m.generation.timestamp = format!("2026-03-{:02}T10:00:00Z", id.min(28));
            m.packages[0].store_path = format!(
                "/nix/store/{}b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-{}.0",
                id, id
            );
            m.packages[1].store_path = SP_UUTILS.into();
            fs::write(gd.join("manifest.json"), serde_json::to_string(&m).unwrap()).unwrap();

            // Create GC roots
            let _ = add_generation_gc_roots(&gc_roots, id, &m.packages);
        }

        // Write current manifest
        let mut current = sample_manifest();
        current.generation.id = current_id;
        fs::write(&manifest_file, serde_json::to_string(&current).unwrap()).unwrap();

        (gen_dir, manifest_file, gc_roots, boot_default_path)
    }

    #[test]
    fn parse_selector_old() {
        assert_eq!(parse_generation_selector("old").unwrap(), GenerationSelector::Old);
    }

    #[test]
    fn parse_selector_keep_last() {
        assert_eq!(parse_generation_selector("+3").unwrap(), GenerationSelector::KeepLast(3));
    }

    #[test]
    fn parse_selector_older_than_days() {
        assert_eq!(parse_generation_selector("14d").unwrap(), GenerationSelector::OlderThanDays(14));
    }

    #[test]
    fn parse_selector_ids() {
        assert_eq!(parse_generation_selector("1 3 5").unwrap(), GenerationSelector::Ids(vec![1, 3, 5]));
    }

    #[test]
    fn parse_selector_invalid() {
        assert!(parse_generation_selector("").is_err());
        assert!(parse_generation_selector("+0").is_err());
        assert!(parse_generation_selector("abc").is_err());
    }

    #[test]
    fn delete_generations_by_id() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 5, 5);

        let stats = delete_generations_with(
            &gc_roots, "1 3", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 2);
        assert!(stats.deleted_ids.contains(&1));
        assert!(stats.deleted_ids.contains(&3));
        assert!(!gen_dir.join("1").exists());
        assert!(!gen_dir.join("3").exists());
        assert!(gen_dir.join("2").exists());
        assert!(gen_dir.join("4").exists());
        assert!(gen_dir.join("5").exists());

        // GC roots for 1 and 3 removed
        let names = root_names(&gc_roots);
        assert!(!names.iter().any(|n| n.starts_with("gen-1-")));
        assert!(!names.iter().any(|n| n.starts_with("gen-3-")));
        // 2, 4, 5 roots intact
        assert!(names.iter().any(|n| n.starts_with("gen-2-")));
        assert!(names.iter().any(|n| n.starts_with("gen-4-")));
        assert!(names.iter().any(|n| n.starts_with("gen-5-")));
    }

    #[test]
    fn delete_generations_keep_last_n() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 8, 8);

        let stats = delete_generations_with(
            &gc_roots, "+3", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 5); // 1-5 deleted, 6-8 kept
        for id in 1..=5 {
            assert!(!gen_dir.join(id.to_string()).exists(), "gen {id} should be deleted");
        }
        for id in 6..=8 {
            assert!(gen_dir.join(id.to_string()).exists(), "gen {id} should be kept");
        }
    }

    #[test]
    fn delete_generations_old() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 4, 4);

        let stats = delete_generations_with(
            &gc_roots, "old", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 3); // 1, 2, 3 deleted
        assert!(!gen_dir.join("1").exists());
        assert!(!gen_dir.join("2").exists());
        assert!(!gen_dir.join("3").exists());
        assert!(gen_dir.join("4").exists()); // current protected
    }

    #[test]
    fn delete_generations_protects_current() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 3, 3);

        let stats = delete_generations_with(
            &gc_roots, "3", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        // Current generation protected
        assert_eq!(stats.generations_deleted, 0);
        assert!(stats.protected_ids.contains(&3));
        assert!(gen_dir.join("3").exists());
    }

    #[test]
    fn delete_generations_protects_boot_default() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 5, 5);

        // Set boot-default to generation 3
        fs::write(&boot_default, "3\n").unwrap();

        let stats = delete_generations_with(
            &gc_roots, "old", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        // Gen 3 (boot-default) and 5 (current) protected
        assert_eq!(stats.generations_deleted, 3); // 1, 2, 4 deleted
        assert!(gen_dir.join("3").exists());
        assert!(gen_dir.join("5").exists());
        assert!(!gen_dir.join("1").exists());
        assert!(!gen_dir.join("2").exists());
        assert!(!gen_dir.join("4").exists());
    }

    #[test]
    fn delete_generations_dry_run() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 3, 3);

        let stats = delete_generations_with(
            &gc_roots, "old", true, // dry_run
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 2); // would delete 1, 2
        // But nothing actually deleted
        assert!(gen_dir.join("1").exists());
        assert!(gen_dir.join("2").exists());
        // GC roots still intact
        let names = root_names(&gc_roots);
        assert!(names.iter().any(|n| n.starts_with("gen-1-")));
        assert!(names.iter().any(|n| n.starts_with("gen-2-")));
    }

    #[test]
    fn delete_generations_nothing_to_delete() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 1, 1);

        let stats = delete_generations_with(
            &gc_roots, "old", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 0);
        assert!(gen_dir.join("1").exists());
    }

    #[test]
    fn parse_timestamp_known_date() {
        let epoch = parse_timestamp_to_epoch("2026-03-16T10:00:00Z");
        // 2026-03-16 should be well after epoch
        assert!(epoch > 1_700_000_000);
    }

    #[test]
    fn parse_timestamp_invalid() {
        assert_eq!(parse_timestamp_to_epoch(""), 0);
        assert_eq!(parse_timestamp_to_epoch("not-a-date"), 0);
    }

    // ===== System GC Integration Tests =====

    #[test]
    fn system_gc_prune_then_sweep_simulation() {
        // Simulate the system_gc flow: prune generations, verify store paths
        // become unreferenced, then a store GC would collect them.
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 4, 4);

        // Set up a PathInfoDb in the same tmpdir
        let pathinfo_dir = tmp.path().join("pathinfo");
        let db = crate::pathinfo::PathInfoDb::open_at(pathinfo_dir).unwrap();

        // Register store paths from all generations
        for id in 1..=4u32 {
            let store_path = format!(
                "/nix/store/{}b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-{}.0",
                id, id
            );
            crate::store::register_path(&db, &store_path, "deadbeef", 1000, vec![], vec![]).unwrap();
        }
        crate::store::register_path(&db, SP_UUTILS, "deadbeef", 500, vec![], vec![]).unwrap();

        // Step 1: Prune (keep last 1 = only gen 4)
        let stats = delete_generations_with(
            &gc_roots, "+1", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 3);

        // Step 2: Verify GC root state
        let live = gc_roots.compute_live_set(&db).unwrap();
        // Only gen 4's ion path and shared uutils should be live
        let gen4_ion = "/nix/store/4b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-4.0";
        assert!(live.contains(gen4_ion));
        assert!(live.contains(SP_UUTILS));
        // Gen 1-3 ion paths are dead (their roots were removed)
        for id in 1..=3u32 {
            let dead_path = format!(
                "/nix/store/{}b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-ion-{}.0",
                id, id
            );
            assert!(!live.contains(&dead_path), "gen {id} ion should be dead");
        }
    }

    #[test]
    fn system_gc_dry_run_preserves_everything() {
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 3, 3);

        let stats = delete_generations_with(
            &gc_roots, "old", true,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        // Reports what would happen
        assert_eq!(stats.generations_deleted, 2);
        // But everything is still intact
        assert!(gen_dir.join("1").exists());
        assert!(gen_dir.join("2").exists());
        assert!(gen_dir.join("3").exists());
        let names = root_names(&gc_roots);
        assert!(names.iter().any(|n| n.starts_with("gen-1-")));
        assert!(names.iter().any(|n| n.starts_with("gen-2-")));
        assert!(names.iter().any(|n| n.starts_with("gen-3-")));
    }

    #[test]
    fn system_gc_default_deletes_all_old() {
        // When no --keep is specified, system_gc uses "old" selector
        let tmp = tempfile::tempdir().unwrap();
        let (gen_dir, manifest_file, gc_roots, boot_default) = setup_generations(&tmp, 5, 5);

        let stats = delete_generations_with(
            &gc_roots, "old", false,
            Some(gen_dir.to_str().unwrap()),
            Some(manifest_file.to_str().unwrap()),
            Some(boot_default.to_str().unwrap()),
        ).unwrap();

        assert_eq!(stats.generations_deleted, 4);
        for id in 1..=4 {
            assert!(!gen_dir.join(id.to_string()).exists());
        }
        assert!(gen_dir.join("5").exists());
    }

    // ── Boot component manifest tests ──

    #[test]
    fn parse_v1_manifest_no_boot_section() {
        let m = sample_manifest();
        assert_eq!(m.manifest_version, 1);
        assert!(m.boot.is_none());
    }

    #[test]
    fn parse_v1_json_without_boot_field() {
        let json = serde_json::to_string(&sample_manifest()).unwrap();
        // v1 manifest serialized without boot field (skip_serializing_if = None)
        assert!(!json.contains("\"boot\":{\"kernel\""));
        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        assert!(parsed.boot.is_none());
    }

    #[test]
    fn parse_v2_manifest_with_boot_paths() {
        let mut m = sample_manifest();
        m.manifest_version = 2;
        m.boot = Some(BootComponents {
            kernel: Some("/nix/store/abc-kernel/boot/kernel".to_string()),
            initfs: Some("/nix/store/def-initfs/boot/initfs".to_string()),
            bootloader: Some("/nix/store/ghi-bootloader/boot/EFI/BOOT/BOOTX64.EFI".to_string()),
        });

        let json = serde_json::to_string(&m).unwrap();
        assert!(json.contains("abc-kernel"));
        assert!(json.contains("def-initfs"));
        assert!(json.contains("ghi-bootloader"));

        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        let boot = parsed.boot.unwrap();
        assert_eq!(boot.kernel.unwrap(), "/nix/store/abc-kernel/boot/kernel");
        assert_eq!(boot.initfs.unwrap(), "/nix/store/def-initfs/boot/initfs");
        assert_eq!(boot.bootloader.unwrap(), "/nix/store/ghi-bootloader/boot/EFI/BOOT/BOOTX64.EFI");
    }

    #[test]
    fn roundtrip_v2_manifest_preserves_boot() {
        let mut m = sample_manifest();
        m.manifest_version = 2;
        m.boot = Some(BootComponents {
            kernel: Some("/nix/store/k1/boot/kernel".to_string()),
            initfs: Some("/nix/store/i1/boot/initfs".to_string()),
            bootloader: None, // partial — bootloader omitted
        });

        let json = serde_json::to_string_pretty(&m).unwrap();
        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        let boot = parsed.boot.unwrap();
        assert_eq!(boot.kernel.unwrap(), "/nix/store/k1/boot/kernel");
        assert_eq!(boot.initfs.unwrap(), "/nix/store/i1/boot/initfs");
        assert!(boot.bootloader.is_none());
    }

    #[test]
    fn v1_json_with_extra_fields_parses() {
        // Simulate a v2 manifest read by v1-era code: extra fields ignored
        let mut m = sample_manifest();
        m.manifest_version = 2;
        m.boot = Some(BootComponents {
            kernel: Some("/nix/store/k/boot/kernel".to_string()),
            initfs: None,
            bootloader: None,
        });
        let json = serde_json::to_string(&m).unwrap();

        // Parse succeeds (serde default handles missing/extra gracefully)
        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.manifest_version, 2);
        assert!(parsed.boot.is_some());
    }

}
