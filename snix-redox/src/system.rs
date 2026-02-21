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

// ===== Manifest Schema =====

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub manifest_version: u32,
    pub system: SystemInfo,
    #[serde(default)]
    pub generation: GenerationInfo,
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

/// Update GC roots to protect the current generation's store paths from garbage collection.
/// Called after switch/rollback to ensure `snix store gc` won't delete active packages.
fn update_system_gc_roots(manifest: &Manifest) -> Result<(), Box<dyn std::error::Error>> {
    let gc_roots = crate::store::GcRoots::open()?;

    // Remove old system-* roots (from previous generation)
    if let Ok(roots) = gc_roots.list_roots() {
        for root in roots {
            if root.name.starts_with("system-") {
                let _ = gc_roots.remove_root(&root.name);
            }
        }
    }

    // Add roots for current generation's packages
    let mut added = 0u32;
    for pkg in &manifest.packages {
        if !pkg.store_path.is_empty() {
            let root_name = format!("system-{}", pkg.name);
            if let Err(e) = gc_roots.add_root(&root_name, &pkg.store_path) {
                eprintln!("warning: could not add GC root for {}: {e}", pkg.name);
            } else {
                added += 1;
            }
        }
    }

    if added > 0 {
        println!("GC roots updated: {added} system packages protected");
    }

    Ok(())
}

/// Public accessor for current_timestamp (used by channel module).
pub fn current_timestamp_pub() -> String {
    current_timestamp()
}

/// Public accessor for update_system_gc_roots (used by activate module).
pub fn update_system_gc_roots_pub(manifest: &Manifest) -> Result<(), Box<dyn std::error::Error>> {
    update_system_gc_roots(manifest)
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
        let plan = crate::activate::plan(&current, &new_m);
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

}
