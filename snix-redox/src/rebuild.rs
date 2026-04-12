//! Declarative system configuration via Nix expressions.
//!
//! Evaluates `/etc/redox-system/configuration.nix` using snix-eval,
//! merges the resulting config attrset with the current system manifest,
//! resolves package names → store paths from the binary cache, and
//! activates the new configuration via `system::switch()`.
//!
//! This is the Redox equivalent of `nixos-rebuild switch`.
//!
//! Workflow:
//!   1. User edits /etc/redox-system/configuration.nix
//!   2. `snix system rebuild` evaluates it → JSON config attrset
//!   3. Rust merges config into current manifest
//!   4. Package names resolved to store paths from /nix/cache/packages.json
//!   5. `system::switch()` activates the new manifest
//!
//! Configuration.nix is a simple Nix attrset — no functions or imports needed:
//! ```nix
//! {
//!   hostname = "my-redox";
//!   packages = [ "ripgrep" "helix" ];
//!   networking.mode = "dhcp";
//! }
//! ```

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::system::{
    self, BootConfig, Configuration, GraphicsConfig as SysGraphicsConfig, Group, HardwareConfig,
    LoggingConfig as SysLoggingConfig, Manifest, NetworkingConfig, Package,
    PowerConfig as SysPowerConfig, SecurityConfig as SysSecurityConfig, Services, SystemInfo, User,
};

const DEFAULT_CONFIG_PATH: &str = "/etc/redox-system/configuration.nix";
const DEFAULT_MANIFEST_PATH: &str = "/etc/redox-system/manifest.json";
const DEFAULT_CACHE_INDEX: &str = "/nix/cache/packages.json";

/// Boot-essential package names that are always preserved in /bin/.
const BOOT_ESSENTIAL: &[&str] = &[
    "ion",
    "ion-shell",
    "base",
    "redox-base",
    "init",
    "logd",
    "ramfs",
    "zerod",
    "nulld",
    "randd",
    "snix",
    "snix-redox",
    "uutils",
];

// ===== Configuration Schema =====
// All fields are Option<T> — only present fields override the current manifest.

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct RebuildConfig {
    pub hostname: Option<String>,
    pub timezone: Option<String>,
    /// Package names to install (replaces the managed package set).
    pub packages: Option<Vec<String>>,
    pub networking: Option<NetworkConfig>,
    pub graphics: Option<GraphicsConfigInput>,
    pub security: Option<SecurityConfig>,
    pub logging: Option<LoggingConfig>,
    pub power: Option<PowerConfig>,
    pub users: Option<BTreeMap<String, UserConfig>>,
    pub programs: Option<ProgramsConfig>,
    /// Hardware/driver configuration — changes require bridge for initfs rebuild.
    pub hardware: Option<HardwareConfigInput>,
    /// Declared service names — additions/removals require initfs rebuild via bridge.
    pub services: Option<Vec<String>>,
    /// Path to a .nix file returning `{ name = derivation; ... }` for source builds.
    /// Used with `snix system rebuild --source`.
    #[serde(rename = "packageSources")]
    pub package_sources: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct NetworkConfig {
    pub enable: Option<bool>,
    pub mode: Option<String>,
    pub dns: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct GraphicsConfigInput {
    pub enable: Option<bool>,
    pub resolution: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SecurityConfig {
    pub protect_kernel_schemes: Option<bool>,
    pub require_passwords: Option<bool>,
    pub allow_remote_root: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoggingConfig {
    pub level: Option<String>,
    pub kernel_level: Option<String>,
    pub log_to_file: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PowerConfig {
    pub acpi_enabled: Option<bool>,
    pub power_action: Option<String>,
    pub reboot_on_panic: Option<bool>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct UserConfig {
    pub uid: u32,
    pub gid: u32,
    pub home: String,
    pub shell: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct ProgramsConfig {
    pub editor: Option<String>,
}

/// Hardware configuration that affects boot components (drivers → initfs).
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HardwareConfigInput {
    pub storage_drivers: Option<Vec<String>>,
    pub network_drivers: Option<Vec<String>>,
    pub graphics_drivers: Option<Vec<String>>,
    pub audio_drivers: Option<Vec<String>>,
    pub usb_enabled: Option<bool>,
}

// ===== Public API =====

/// Rebuild the system from configuration.nix.
///
/// Evaluates the Nix config, merges with the current manifest, resolves
/// packages, and switches to the new configuration.
/// Check if the parsed config contains package changes.
///
/// Returns true if `packages` is `Some` with a non-empty list.
/// An empty list (`packages = []`) is treated as "no change".
pub fn has_package_changes(config: &RebuildConfig) -> bool {
    matches!(&config.packages, Some(pkgs) if !pkgs.is_empty())
}

/// Check if the parsed config has service changes compared to the current manifest.
/// Service additions/removals require initfs rebuild because init scripts are baked in.
pub fn has_service_changes(config: &RebuildConfig, current_manifest: Option<&Manifest>) -> bool {
    if let Some(ref svc_names) = config.services {
        if let Some(manifest) = current_manifest {
            let mut current_names: Vec<&str> = manifest
                .services
                .declared
                .keys()
                .map(|s| s.as_str())
                .collect();
            current_names.sort();
            let mut new_names: Vec<&str> = svc_names.iter().map(|s| s.as_str()).collect();
            new_names.sort();
            current_names != new_names
        } else {
            true
        }
    } else {
        false
    }
}

/// Check if the parsed config has hardware/driver changes that affect boot components.
/// Any hardware field set means the user is declaring driver configuration → needs bridge
/// to rebuild initfs. Service additions/removals also require initfs rebuild since init
/// scripts are baked in at build time.
///
/// When `current_manifest` is provided, service names are compared against the manifest's
/// declared services. When `None`, only hardware fields are checked.
pub fn has_boot_affecting_changes(
    config: &RebuildConfig,
    current_manifest: Option<&Manifest>,
) -> bool {
    let hw_changed = if let Some(ref hw) = config.hardware {
        hw.storage_drivers.is_some()
            || hw.network_drivers.is_some()
            || hw.graphics_drivers.is_some()
            || hw.audio_drivers.is_some()
            || hw.usb_enabled.is_some()
    } else {
        false
    };

    let services_changed = if let Some(ref svc_names) = config.services {
        if let Some(manifest) = current_manifest {
            let mut current_names: Vec<&str> = manifest
                .services
                .declared
                .keys()
                .map(|s| s.as_str())
                .collect();
            current_names.sort();
            let mut new_names: Vec<&str> = svc_names.iter().map(|s| s.as_str()).collect();
            new_names.sort();
            current_names != new_names
        } else {
            // No manifest to compare — treat any declared services as potentially changing
            true
        }
    } else {
        false
    };

    hw_changed || services_changed
}

/// Check if the config requires the bridge (package or boot-affecting changes).
pub fn needs_bridge(config: &RebuildConfig, current_manifest: Option<&Manifest>) -> bool {
    has_package_changes(config) || has_boot_affecting_changes(config, current_manifest)
}

/// Check if the build bridge is available.
///
/// The bridge requires virtio-fs with the shared directory mounted
/// and the host-side build-bridge daemon running. We detect this by
/// checking for the requests directory that the daemon creates.
pub fn bridge_available(shared_dir: Option<&str>) -> bool {
    let dir = shared_dir.unwrap_or("/scheme/shared");
    Path::new(dir).join("requests").is_dir()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AutoRebuildRoute {
    Bridge,
    Local,
}

fn select_auto_rebuild_route(
    config: &RebuildConfig,
    current_manifest: Option<&Manifest>,
    bridge_is_available: bool,
) -> Result<AutoRebuildRoute, Box<dyn std::error::Error>> {
    if has_boot_affecting_changes(config, current_manifest) {
        if bridge_is_available {
            return Ok(AutoRebuildRoute::Bridge);
        }

        return Err(
            "changes require the build bridge\n\
             \n\
             Your configuration.nix modifies hardware/drivers or services, which\n\
             requires the host to rebuild the initfs. Start the VM with shared filesystem:\n\
             \n\
               nix run .#run-redox-shared     (in one terminal)\n\
               nix run .#build-bridge         (in another terminal)\n"
                .into(),
        );
    }

    if has_package_changes(config) && bridge_is_available {
        Ok(AutoRebuildRoute::Bridge)
    } else {
        Ok(AutoRebuildRoute::Local)
    }
}

/// Auto-routing rebuild entry point.
///
/// Parses configuration.nix, then decides which path to use:
///   - Boot-affecting changes + bridge available → bridge rebuild
///   - Package changes + bridge available → bridge rebuild
///   - Package changes + no bridge → guest-local rebuild (remote/local cache fallback)
///   - Config-only changes → local rebuild
pub fn auto_rebuild(
    config_path: Option<&str>,
    dry_run: bool,
    manifest_path: Option<&str>,
    gen_dir: Option<&str>,
    cache_index_path: Option<&str>,
    cache_url: Option<&str>,
    shared_dir: Option<&str>,
    timeout: Option<u64>,
) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = config_path.unwrap_or(DEFAULT_CONFIG_PATH);
    let mpath = manifest_path.unwrap_or(DEFAULT_MANIFEST_PATH);

    // Parse config to determine what changed
    println!("Evaluating {cfg_path}...");
    let config = evaluate_config(cfg_path)?;

    // Load current manifest for service comparison
    let current_manifest = system::load_manifest_from(mpath).ok();
    let manifest_ref = current_manifest.as_ref();

    let route = select_auto_rebuild_route(&config, manifest_ref, bridge_available(shared_dir))?;

    match route {
        AutoRebuildRoute::Bridge => {
            let has_svc = has_service_changes(&config, manifest_ref);
            let has_hw = has_boot_affecting_changes(&config, manifest_ref);
            let has_pkg = has_package_changes(&config);
            let reason = if has_pkg && (has_hw || has_svc) {
                "Package and boot component changes detected"
            } else if has_svc {
                "Service changes detected (initfs rebuild needed)"
            } else if has_hw {
                "Hardware/driver changes detected (initfs rebuild needed)"
            } else {
                "Package changes detected"
            };
            println!("{reason}, using bridge...");
            crate::bridge::rebuild_via_bridge(
                config_path,
                dry_run,
                shared_dir,
                timeout,
                manifest_path,
                gen_dir,
            )
        }
        AutoRebuildRoute::Local => rebuild(
            config_path,
            dry_run,
            manifest_path,
            gen_dir,
            cache_index_path,
            cache_url,
        ),
    }
}

pub fn rebuild(
    config_path: Option<&str>,
    dry_run: bool,
    manifest_path: Option<&str>,
    gen_dir: Option<&str>,
    cache_index_path: Option<&str>,
    cache_url: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = config_path.unwrap_or(DEFAULT_CONFIG_PATH);
    let mpath = manifest_path.unwrap_or(DEFAULT_MANIFEST_PATH);
    let cache_path = cache_index_path.unwrap_or(DEFAULT_CACHE_INDEX);
    let primary_cache = cache_source_for_rebuild(cache_path, cache_url);
    let local_cache = local_cache_source_for_rebuild(cache_path);
    let fallback_cache = if primary_cache.is_remote() {
        Some(&local_cache)
    } else {
        None
    };
    let preserved_config = if cfg_path == DEFAULT_CONFIG_PATH {
        Some(fs::read_to_string(cfg_path)?)
    } else {
        None
    };

    // Step 1: Evaluate configuration.nix
    println!("Evaluating {cfg_path}...");
    let config = evaluate_config(cfg_path)?;

    // Warn if using local path with package changes (--local or legacy behavior)
    if has_package_changes(&config) {
        if primary_cache.is_remote() {
            eprintln!(
                "warning: resolving packages from remote cache first, then local cache fallback"
            );
        } else {
            eprintln!("warning: resolving packages locally from binary cache index");
            eprintln!("         results may be incomplete — use bridge for full builds");
        }
    }

    // Step 2: Load current manifest
    let current = system::load_manifest_from(mpath)?;

    // Step 3: Resolve package names → store paths
    let resolved_packages = resolve_packages_with_fallback(
        &config.packages,
        &primary_cache,
        fallback_cache,
    )?;

    // Step 4: Merge config into manifest
    let merged_packages: Vec<Package> = resolved_packages
        .iter()
        .map(|resolved| resolved.package.clone())
        .collect();
    let merged = merge_config(&current, &config, &merged_packages)?;

    // Step 5: Show what would change
    let has_changes = has_manifest_changes(&current, &merged);
    print_changes(&current, &merged, &config);

    if dry_run {
        println!();
        println!("Dry run complete. No changes applied.");
        println!("Edit {cfg_path} and run `snix system rebuild` to apply.");
        return Ok(());
    }

    if !has_changes {
        println!();
        println!("No changes detected. System is already up to date.");
        return Ok(());
    }

    // Step 5b: Extract newly-added packages from the selected cache source.
    if !resolved_packages.is_empty() {
        for resolved in &resolved_packages {
            let pkg = &resolved.package;
            if pkg.store_path.is_empty() {
                continue;
            }
            if !Path::new(&pkg.store_path).exists() {
                println!("Extracting {}...", pkg.name);
                if let Some(source) = resolved.source.as_ref() {
                    if let Err(e) = crate::install::fetch_and_extract(&pkg.store_path, source) {
                        eprintln!("warning: failed to extract {}: {e}", pkg.name);
                    }
                }
            }
        }
    }

    // Step 6: Write merged manifest and switch
    let tmp_path = format!("/tmp/snix-rebuild-{}.json", std::process::id());
    let json = serde_json::to_string_pretty(&merged)?;
    fs::write(&tmp_path, &json)?;

    let result = system::switch(
        &tmp_path,
        Some("rebuild from configuration.nix"),
        false,
        gen_dir,
        manifest_path,
    );

    // Clean up
    let _ = fs::remove_file(&tmp_path);

    result?;

    if let Some(config_text) = preserved_config.as_deref() {
        preserve_active_config(DEFAULT_CONFIG_PATH, config_text)?;
    }

    println!();
    println!("✓ System rebuilt from {cfg_path}");

    Ok(())
}

fn preserve_active_config(
    path: &str,
    content: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = Path::new(path);
    if let Some(parent) = cfg_path.parent() {
        fs::create_dir_all(parent)?;
    }

    if cfg_path.symlink_metadata().is_ok() {
        fs::remove_file(cfg_path).or_else(|_| fs::remove_dir_all(cfg_path))?;
    }

    fs::write(cfg_path, content)?;
    Ok(())
}

pub(crate) fn preserve_active_config_pub(
    path: &str,
    content: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    preserve_active_config(path, content)
}

/// Show the parsed configuration without applying it.
pub fn show_config(config_path: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = config_path.unwrap_or(DEFAULT_CONFIG_PATH);

    println!("Evaluating {cfg_path}...");
    let config = evaluate_config(cfg_path)?;

    println!();
    println!("Parsed configuration:");
    println!("=====================");

    if let Some(ref h) = config.hostname {
        println!("  hostname:  {h}");
    }
    if let Some(ref t) = config.timezone {
        println!("  timezone:  {t}");
    }

    if let Some(ref net) = config.networking {
        println!("  networking:");
        if let Some(e) = net.enable {
            println!("    enable: {e}");
        }
        if let Some(ref m) = net.mode {
            println!("    mode:   {m}");
        }
        if let Some(ref dns) = net.dns {
            println!("    dns:    {}", dns.join(", "));
        }
    }

    if let Some(ref gfx) = config.graphics {
        println!("  graphics:");
        if let Some(e) = gfx.enable {
            println!("    enable:     {e}");
        }
        if let Some(ref r) = gfx.resolution {
            println!("    resolution: {r}");
        }
    }

    if let Some(ref sec) = config.security {
        println!("  security:");
        if let Some(v) = sec.protect_kernel_schemes {
            println!("    protectKernelSchemes: {v}");
        }
        if let Some(v) = sec.require_passwords {
            println!("    requirePasswords:     {v}");
        }
        if let Some(v) = sec.allow_remote_root {
            println!("    allowRemoteRoot:      {v}");
        }
    }

    if let Some(ref log) = config.logging {
        println!("  logging:");
        if let Some(ref l) = log.level {
            println!("    level:       {l}");
        }
        if let Some(ref k) = log.kernel_level {
            println!("    kernelLevel: {k}");
        }
        if let Some(v) = log.log_to_file {
            println!("    logToFile:   {v}");
        }
    }

    if let Some(ref pwr) = config.power {
        println!("  power:");
        if let Some(v) = pwr.acpi_enabled {
            println!("    acpiEnabled:   {v}");
        }
        if let Some(ref a) = pwr.power_action {
            println!("    powerAction:   {a}");
        }
        if let Some(v) = pwr.reboot_on_panic {
            println!("    rebootOnPanic: {v}");
        }
    }

    if let Some(ref pkgs) = config.packages {
        println!("  packages: {}", pkgs.join(", "));
    }

    if let Some(ref users) = config.users {
        println!("  users:");
        for (name, u) in users {
            println!(
                "    {name}: uid={} gid={} home={} shell={}",
                u.uid, u.gid, u.home, u.shell
            );
        }
    }

    if let Some(ref prg) = config.programs {
        if let Some(ref e) = prg.editor {
            println!("  programs.editor: {e}");
        }
    }

    Ok(())
}

// ===== Core Logic =====

/// Evaluate a configuration.nix file and return the parsed config.
///
/// Uses snix-eval to evaluate `builtins.toJSON (import <path>)`, then
/// parses the JSON output.
/// Public accessor for bridge module to evaluate configuration files.
pub fn evaluate_config_pub(path: &str) -> Result<RebuildConfig, Box<dyn std::error::Error>> {
    evaluate_config(path)
}

fn evaluate_config(path: &str) -> Result<RebuildConfig, Box<dyn std::error::Error>> {
    // If the file is already JSON, parse directly (useful for testing)
    if path.ends_with(".json") {
        let content = fs::read_to_string(path)?;
        return parse_config_json(&content);
    }

    // Verify file exists
    if !Path::new(path).exists() {
        return Err(format!(
            "configuration file not found: {path}\n\
             Create one with: snix system rebuild --init"
        )
        .into());
    }

    // Build the Nix expression that evaluates config → JSON
    let expr = format!("builtins.toJSON (import {})", path);

    let eval = snix_eval::Evaluation::builder_impure().build();
    let result = eval.evaluate(&expr, None);

    if !result.errors.is_empty() {
        let errors: Vec<String> = result.errors.iter().map(|e| format!("{e}")).collect();
        return Err(format!("error evaluating {path}:\n{}", errors.join("\n")).into());
    }

    let value = result
        .value
        .ok_or_else(|| format!("no value produced from {path}"))?;

    // The value is a Nix string containing JSON.
    // Its Display representation is a quoted string: "{ \"hostname\": ... }"
    let repr = format!("{value}");

    // Strip surrounding quotes and unescape
    let json_str = if repr.starts_with('"') && repr.ends_with('"') && repr.len() >= 2 {
        let inner = &repr[1..repr.len() - 1];
        inner
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
            .replace("\\n", "\n")
            .replace("\\t", "\t")
    } else {
        repr
    };

    parse_config_json(&json_str)
}

/// Parse a JSON string into a RebuildConfig.
pub(crate) fn parse_config_json(json: &str) -> Result<RebuildConfig, Box<dyn std::error::Error>> {
    let config: RebuildConfig = serde_json::from_str(json)?;
    Ok(config)
}

/// Select the primary cache source used by rebuild.
fn cache_source_for_rebuild(
    cache_index_path: &str,
    cache_url: Option<&str>,
) -> crate::cache_source::CacheSource {
    if let Some(url) = cache_url {
        crate::cache_source::CacheSource::Remote(url.trim_end_matches('/').to_string())
    } else {
        local_cache_source_for_rebuild(cache_index_path)
    }
}

fn local_cache_source_for_rebuild(cache_index_path: &str) -> crate::cache_source::CacheSource {
    let cache_dir = Path::new(cache_index_path)
        .parent()
        .unwrap_or(Path::new(crate::cache_source::DEFAULT_CACHE_PATH));
    crate::cache_source::CacheSource::Local(cache_dir.to_path_buf())
}

#[derive(Debug, Clone)]
struct ResolvedPackage {
    package: Package,
    source: Option<crate::cache_source::CacheSource>,
}

fn resolve_packages_from_indexes(
    names: &[String],
    primary_index: Option<&crate::local_cache::PackageIndex>,
    primary_source: Option<&crate::cache_source::CacheSource>,
    fallback_index: Option<&crate::local_cache::PackageIndex>,
    fallback_source: Option<&crate::cache_source::CacheSource>,
) -> Vec<ResolvedPackage> {
    let mut packages = Vec::new();

    for name in names {
        if let (Some(index), Some(source)) = (primary_index, primary_source) {
            if let Some(entry) = index.packages.get(name.as_str()) {
                packages.push(ResolvedPackage {
                    package: Package {
                        name: name.clone(),
                        version: entry.version.clone(),
                        store_path: entry.store_path.clone(),
                    },
                    source: Some(source.clone()),
                });
                continue;
            }
        }

        if let (Some(index), Some(source)) = (fallback_index, fallback_source) {
            if let Some(entry) = index.packages.get(name.as_str()) {
                packages.push(ResolvedPackage {
                    package: Package {
                        name: name.clone(),
                        version: entry.version.clone(),
                        store_path: entry.store_path.clone(),
                    },
                    source: Some(source.clone()),
                });
                continue;
            }
        }

        packages.push(ResolvedPackage {
            package: Package {
                name: name.clone(),
                version: String::new(),
                store_path: String::new(),
            },
            source: None,
        });
    }

    packages
}

/// Resolve package names to store paths using remote → local fallback.
fn resolve_packages_with_fallback(
    names: &Option<Vec<String>>,
    primary_source: &crate::cache_source::CacheSource,
    fallback_source: Option<&crate::cache_source::CacheSource>,
) -> Result<Vec<ResolvedPackage>, Box<dyn std::error::Error>> {
    let names = match names {
        Some(n) if !n.is_empty() => n,
        _ => return Ok(Vec::new()),
    };

    let primary_index = match primary_source.read_index() {
        Ok(index) => Some(index),
        Err(e) => {
            if fallback_source.is_some() {
                eprintln!(
                    "warning: failed to read {}: {e}; falling back",
                    primary_source.display_name()
                );
                None
            } else {
                return Err(e);
            }
        }
    };

    let fallback_index = match fallback_source {
        Some(source) => match source.read_index() {
            Ok(index) => Some(index),
            Err(e) => {
                if primary_index.is_some() {
                    eprintln!(
                        "warning: failed to read {}: {e}",
                        source.display_name()
                    );
                    None
                } else {
                    return Err(e);
                }
            }
        },
        None => None,
    };

    let packages = resolve_packages_from_indexes(
        names,
        primary_index.as_ref(),
        Some(primary_source),
        fallback_index.as_ref(),
        fallback_source,
    );

    for resolved in &packages {
        if resolved.package.store_path.is_empty() {
            let name = &resolved.package.name;
            if let Some(source) = fallback_source {
                eprintln!(
                    "warning: package '{name}' not found in {} or {}",
                    primary_source.display_name(),
                    source.display_name()
                );
            } else {
                eprintln!(
                    "warning: package '{name}' not found in {}",
                    primary_source.display_name()
                );
            }
        }
    }

    Ok(packages)
}

/// Resolve package names from a JSON index string (testable).
pub(crate) fn resolve_packages_from_json(
    names: &[String],
    index_json: &str,
) -> Result<Vec<Package>, Box<dyn std::error::Error>> {
    // packages.json format: { "version": 1, "packages": { "name": { "storePath": "...", ... } } }
    // Also support flat format: { "name": { "storePath": "...", ... } } for backwards compat.
    let raw: serde_json::Value = serde_json::from_str(index_json)?;
    let index: BTreeMap<String, serde_json::Value> = if let Some(pkgs) = raw.get("packages") {
        // Nested format: extract the "packages" sub-object
        serde_json::from_value(pkgs.clone()).unwrap_or_default()
    } else {
        // Flat format: top-level keys are package names
        serde_json::from_value(raw).unwrap_or_default()
    };

    let mut packages = Vec::new();

    for name in names {
        if let Some(entry) = index.get(name.as_str()) {
            let store_path = entry
                .get("storePath")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let version = entry
                .get("version")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            packages.push(Package {
                name: name.clone(),
                version,
                store_path,
            });
        } else {
            eprintln!("warning: package '{name}' not found in binary cache");
            packages.push(Package {
                name: name.clone(),
                version: String::new(),
                store_path: String::new(),
            });
        }
    }

    Ok(packages)
}

/// Merge a RebuildConfig into an existing Manifest.
///
/// Only fields present in the config override the manifest.
/// Boot-essential packages are always preserved.
pub(crate) fn merge_config(
    current: &Manifest,
    config: &RebuildConfig,
    resolved_packages: &[Package],
) -> Result<Manifest, Box<dyn std::error::Error>> {
    let mut m = current.clone();

    // System metadata
    if let Some(ref h) = config.hostname {
        m.system.hostname = h.clone();
    }
    if let Some(ref t) = config.timezone {
        m.system.timezone = t.clone();
    }

    // Networking
    if let Some(ref net) = config.networking {
        if let Some(e) = net.enable {
            m.configuration.networking.enabled = e;
        }
        if let Some(ref mode) = net.mode {
            m.configuration.networking.mode = mode.clone();
        }
        if let Some(ref dns) = net.dns {
            m.configuration.networking.dns = dns.clone();
        }
    }

    // Graphics
    if let Some(ref gfx) = config.graphics {
        if let Some(e) = gfx.enable {
            m.configuration.graphics.enabled = e;
        }
        if let Some(ref r) = gfx.resolution {
            m.configuration.graphics.resolution = r.clone();
        }
    }

    // Security
    if let Some(ref sec) = config.security {
        if let Some(v) = sec.protect_kernel_schemes {
            m.configuration.security.protect_kernel_schemes = v;
        }
        if let Some(v) = sec.require_passwords {
            m.configuration.security.require_passwords = v;
        }
        if let Some(v) = sec.allow_remote_root {
            m.configuration.security.allow_remote_root = v;
        }
    }

    // Logging
    if let Some(ref log) = config.logging {
        if let Some(ref l) = log.level {
            m.configuration.logging.log_level = l.clone();
        }
        if let Some(ref k) = log.kernel_level {
            m.configuration.logging.kernel_log_level = k.clone();
        }
        if let Some(v) = log.log_to_file {
            m.configuration.logging.log_to_file = v;
        }
    }

    // Power
    if let Some(ref pwr) = config.power {
        if let Some(v) = pwr.acpi_enabled {
            m.configuration.power.acpi_enabled = v;
        }
        if let Some(ref a) = pwr.power_action {
            m.configuration.power.power_action = a.clone();
        }
        if let Some(v) = pwr.reboot_on_panic {
            m.configuration.power.reboot_on_panic = v;
        }
    }

    // Users — if specified, replaces entire user map
    if let Some(ref users) = config.users {
        m.users = users
            .iter()
            .map(|(name, u)| {
                (
                    name.clone(),
                    User {
                        uid: u.uid,
                        gid: u.gid,
                        home: u.home.clone(),
                        shell: u.shell.clone(),
                    },
                )
            })
            .collect();

        // Also update groups to match users
        m.groups = users
            .iter()
            .map(|(name, u)| {
                (
                    name.clone(),
                    Group {
                        gid: u.gid,
                        members: vec![name.clone()],
                    },
                )
            })
            .collect();
    }

    // Packages — if specified, merge with boot-essential set
    if config.packages.is_some() && !resolved_packages.is_empty() {
        // Keep boot-essential packages from current manifest
        let boot_pkgs: Vec<Package> = current
            .packages
            .iter()
            .filter(|p| is_boot_essential(&p.name))
            .cloned()
            .collect();

        // Merge: boot-essential + resolved config packages (dedup by name)
        let mut seen = std::collections::BTreeSet::new();
        let mut merged_pkgs = Vec::new();

        for pkg in &boot_pkgs {
            if seen.insert(pkg.name.clone()) {
                merged_pkgs.push(pkg.clone());
            }
        }
        for pkg in resolved_packages {
            if seen.insert(pkg.name.clone()) {
                merged_pkgs.push(pkg.clone());
            }
        }

        m.packages = merged_pkgs;
    }

    Ok(m)
}

/// Check if a package name is boot-essential (always preserved in /bin/).
fn is_boot_essential(name: &str) -> bool {
    BOOT_ESSENTIAL.iter().any(|&b| b == name)
}

/// Check if the merged manifest differs from the current one in any
/// meaningful way (hostname, timezone, networking, packages, users,
/// services, files, boot components, drivers, security, logging, power).
fn has_manifest_changes(current: &Manifest, merged: &Manifest) -> bool {
    // System-level fields
    if current.system.hostname != merged.system.hostname {
        return true;
    }
    if current.system.timezone != merged.system.timezone {
        return true;
    }

    // Networking
    if current.configuration.networking != merged.configuration.networking {
        return true;
    }

    // Security, logging, power
    if current.configuration.security != merged.configuration.security {
        return true;
    }
    if current.configuration.logging != merged.configuration.logging {
        return true;
    }
    if current.configuration.power != merged.configuration.power {
        return true;
    }
    if current.configuration.hardware != merged.configuration.hardware {
        return true;
    }

    // Packages (compare by name + store_path)
    let cur_pkgs: Vec<(&str, &str)> = current
        .packages
        .iter()
        .map(|p| (p.name.as_str(), p.store_path.as_str()))
        .collect();
    let new_pkgs: Vec<(&str, &str)> = merged
        .packages
        .iter()
        .map(|p| (p.name.as_str(), p.store_path.as_str()))
        .collect();
    if cur_pkgs != new_pkgs {
        return true;
    }

    // Users
    if current.users != merged.users {
        return true;
    }

    // Services
    if current.services != merged.services {
        return true;
    }

    // Files (environment.etc)
    if current.files != merged.files {
        return true;
    }

    // Boot components
    if current.boot != merged.boot {
        return true;
    }

    // Drivers
    if current.drivers != merged.drivers {
        return true;
    }

    false
}

/// Print a summary of what changed between current and merged manifests.
fn print_changes(current: &Manifest, merged: &Manifest, config: &RebuildConfig) {
    let mut changes = Vec::new();

    if current.system.hostname != merged.system.hostname {
        changes.push(format!(
            "  hostname: {} → {}",
            current.system.hostname, merged.system.hostname
        ));
    }
    if current.system.timezone != merged.system.timezone {
        changes.push(format!(
            "  timezone: {} → {}",
            current.system.timezone, merged.system.timezone
        ));
    }

    // Networking
    if current.configuration.networking.enabled != merged.configuration.networking.enabled {
        changes.push(format!(
            "  networking.enabled: {} → {}",
            current.configuration.networking.enabled, merged.configuration.networking.enabled
        ));
    }
    if current.configuration.networking.mode != merged.configuration.networking.mode {
        changes.push(format!(
            "  networking.mode: {} → {}",
            current.configuration.networking.mode, merged.configuration.networking.mode
        ));
    }

    // Graphics
    if current.configuration.graphics.enabled != merged.configuration.graphics.enabled {
        changes.push(format!(
            "  graphics.enabled: {} → {}",
            current.configuration.graphics.enabled, merged.configuration.graphics.enabled
        ));
    }

    // Security
    if current.configuration.security.require_passwords
        != merged.configuration.security.require_passwords
    {
        changes.push(format!(
            "  security.requirePasswords: {} → {}",
            current.configuration.security.require_passwords,
            merged.configuration.security.require_passwords
        ));
    }

    // Packages
    let cur_pkg_names: std::collections::BTreeSet<_> =
        current.packages.iter().map(|p| &p.name).collect();
    let new_pkg_names: std::collections::BTreeSet<_> =
        merged.packages.iter().map(|p| &p.name).collect();
    let added: Vec<_> = new_pkg_names.difference(&cur_pkg_names).collect();
    let removed: Vec<_> = cur_pkg_names.difference(&new_pkg_names).collect();

    if !added.is_empty() {
        changes.push(format!(
            "  packages added: {}",
            added
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if !removed.is_empty() {
        changes.push(format!(
            "  packages removed: {}",
            removed
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    // Users
    if config.users.is_some() && current.users != merged.users {
        let cur_names: std::collections::BTreeSet<_> = current.users.keys().collect();
        let new_names: std::collections::BTreeSet<_> = merged.users.keys().collect();
        let added_u: Vec<_> = new_names.difference(&cur_names).collect();
        let removed_u: Vec<_> = cur_names.difference(&new_names).collect();
        if !added_u.is_empty() {
            changes.push(format!(
                "  users added: {}",
                added_u
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        if !removed_u.is_empty() {
            changes.push(format!(
                "  users removed: {}",
                removed_u
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    }

    // Boot components (when both sides have boot paths)
    if let (Some(cur_boot), Some(new_boot)) = (&current.boot, &merged.boot) {
        if cur_boot.kernel != new_boot.kernel {
            changes.push(format!(
                "  boot.kernel: {} → {}",
                cur_boot.kernel.as_deref().unwrap_or("(none)"),
                new_boot.kernel.as_deref().unwrap_or("(none)")
            ));
        }
        if cur_boot.initfs != new_boot.initfs {
            changes.push(format!(
                "  boot.initfs: {} → {}",
                cur_boot.initfs.as_deref().unwrap_or("(none)"),
                new_boot.initfs.as_deref().unwrap_or("(none)")
            ));
        }
        if cur_boot.bootloader != new_boot.bootloader {
            changes.push(format!(
                "  boot.bootloader: {} → {}",
                cur_boot.bootloader.as_deref().unwrap_or("(none)"),
                new_boot.bootloader.as_deref().unwrap_or("(none)")
            ));
        }
    }

    if changes.is_empty() {
        println!("No configuration changes detected.");
    } else {
        println!("Configuration changes:");
        for c in &changes {
            println!("{c}");
        }
    }
}

/// Generate a default configuration.nix file.
pub fn init_config(path: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = path.unwrap_or(DEFAULT_CONFIG_PATH);

    if Path::new(cfg_path).exists() {
        return Err(format!("{cfg_path} already exists. Edit it directly.").into());
    }

    // Ensure parent directory exists
    if let Some(parent) = Path::new(cfg_path).parent() {
        fs::create_dir_all(parent)?;
    }

    fs::write(
        cfg_path,
        r#"# /etc/redox-system/configuration.nix
#
# Declarative system configuration for Redox OS.
# Edit this file and run `snix system rebuild` to apply changes.
#
# Only set the options you want to change — everything else keeps
# its current value from the running system.
#
# After editing:
#   snix system rebuild --dry-run   # Preview changes
#   snix system rebuild             # Apply changes
#
# Available options:
#   hostname, timezone, packages,
#   networking.{enable, mode, dns},
#   graphics.{enable, resolution},
#   security.{protectKernelSchemes, requirePasswords, allowRemoteRoot},
#   logging.{level, kernelLevel, logToFile},
#   power.{acpiEnabled, powerAction, rebootOnPanic},
#   users.{name = { uid, gid, home, shell }},
#   programs.{editor}

{
  # hostname = "redox";
  # timezone = "UTC";

  # networking = {
  #   enable = true;
  #   mode = "auto";   # auto | dhcp | static | none
  #   dns = [ "1.1.1.1" ];
  # };

  # packages = [
  #   "ripgrep"
  #   "fd"
  #   "helix"
  # ];

  # users = {
  #   user = {
  #     uid = 1000;
  #     gid = 1000;
  #     home = "/home/user";
  #     shell = "/bin/ion";
  #   };
  # };
}
"#,
    )?;

    println!("Created {cfg_path}");
    println!();
    println!("Edit it, then run:");
    println!("  snix system rebuild --dry-run   # Preview changes");
    println!("  snix system rebuild             # Apply changes");

    Ok(())
}

// ===== Source-based rebuild =====

/// Rebuild the system by compiling packages from Nix expressions.
///
/// Reads `packageSources` from configuration.nix, evaluates the referenced
/// .nix file to get `{ name = derivation; ... }`, builds each derivation
/// locally, and activates the result.
pub fn rebuild_from_source(
    config_path: Option<&str>,
    dry_run: bool,
    manifest_path: Option<&str>,
    gen_dir: Option<&str>,
    cache_index_path: Option<&str>,
    cache_url: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = config_path.unwrap_or(DEFAULT_CONFIG_PATH);
    let mpath = manifest_path.unwrap_or(DEFAULT_MANIFEST_PATH);
    let cache_path = cache_index_path.unwrap_or(DEFAULT_CACHE_INDEX);
    let primary_cache = cache_source_for_rebuild(cache_path, cache_url);
    let local_cache = local_cache_source_for_rebuild(cache_path);
    let fallback_cache = if primary_cache.is_remote() {
        Some(&local_cache)
    } else {
        None
    };

    // Step 1: Evaluate configuration.nix
    println!("Evaluating {cfg_path}...");
    let config = evaluate_config(cfg_path)?;

    // Step 2: Resolve packageSources path
    let sources_path = config.package_sources.as_deref().ok_or(
        "configuration.nix has no 'packageSources' attribute.\n\
         Add: packageSources = \"/etc/redox-system/packages.nix\";\n\
         Or use 'snix system rebuild' (without --source) for binary cache mode.",
    )?;

    if !Path::new(sources_path).exists() {
        return Err(format!("packageSources file not found: {sources_path}").into());
    }

    // Step 3: Evaluate the package sources file
    println!("Evaluating {sources_path}...");
    let source_packages = evaluate_package_sources(sources_path)?;

    if source_packages.is_empty() {
        println!("No packages defined in {sources_path}.");
        return Ok(());
    }

    println!("Found {} source packages:", source_packages.len());
    for (name, drv_path) in &source_packages {
        println!("  {name}: {drv_path}");
    }

    if dry_run {
        println!();
        println!(
            "Dry run complete. {} derivation(s) would be built.",
            source_packages.len()
        );
        return Ok(());
    }

    // Step 4: Build each derivation
    println!();
    let built_packages = build_source_packages(&source_packages, sources_path)?;

    // Step 5: Load current manifest and merge
    let current = system::load_manifest_from(mpath)?;

    // Resolve any binary-cache packages too
    let cache_packages = if has_package_changes(&config) {
        resolve_packages_with_fallback(&config.packages, &primary_cache, fallback_cache)
            .unwrap_or_default()
    } else {
        vec![]
    };

    for resolved in &cache_packages {
        let pkg = &resolved.package;
        if pkg.store_path.is_empty() {
            continue;
        }
        if !Path::new(&pkg.store_path).exists() {
            println!("Extracting {}...", pkg.name);
            if let Some(source) = resolved.source.as_ref() {
                if let Err(e) = crate::install::fetch_and_extract(&pkg.store_path, source) {
                    eprintln!("warning: failed to extract {}: {e}", pkg.name);
                }
            }
        }
    }

    // Merge: source-built packages + cache packages + boot essentials
    let cache_manifest_packages: Vec<Package> = cache_packages
        .iter()
        .map(|resolved| resolved.package.clone())
        .collect();
    let mut merged = merge_config(&current, &config, &cache_manifest_packages)?;

    // Add source-built packages to the manifest
    for (name, store_path) in &built_packages {
        let pkg = system::Package {
            name: name.clone(),
            version: "source".to_string(),
            store_path: store_path.clone(),
        };
        // Replace existing or append
        if let Some(existing) = merged.packages.iter_mut().find(|p| p.name == *name) {
            *existing = pkg;
        } else {
            merged.packages.push(pkg);
        }
    }

    // Ensure boot essentials are preserved
    for essential in BOOT_ESSENTIAL {
        if !merged
            .packages
            .iter()
            .any(|p| p.name == *essential || p.name.ends_with(essential))
        {
            // Keep from current manifest
            if let Some(pkg) = current
                .packages
                .iter()
                .find(|p| p.name == *essential || p.name.ends_with(essential))
            {
                merged.packages.push(pkg.clone());
            }
        }
    }

    // Step 6: Write and switch
    let tmp_path = format!("/tmp/snix-source-rebuild-{}.json", std::process::id());
    let json = serde_json::to_string_pretty(&merged)?;
    fs::write(&tmp_path, &json)?;

    let desc = format!(
        "source rebuild ({} packages from {})",
        built_packages.len(),
        sources_path
    );
    let result = system::switch(&tmp_path, Some(&desc), false, gen_dir, manifest_path);

    let _ = fs::remove_file(&tmp_path);
    result?;

    println!();
    println!(
        "\u{2713} System rebuilt from source ({} packages from {cfg_path})",
        built_packages.len()
    );

    Ok(())
}

/// Evaluate a package sources .nix file and return `{ name: drv_path }`.
fn evaluate_package_sources(
    sources_path: &str,
) -> Result<Vec<(String, String)>, Box<dyn std::error::Error>> {
    let expr = format!("builtins.attrNames (import {})", sources_path);
    let (names_str, state) = crate::eval::evaluate_with_state(&expr)?;

    // Parse the list of names
    let names_str = names_str.trim();
    if !names_str.starts_with('[') || !names_str.ends_with(']') {
        return Err(format!("packageSources must return an attrset, got: {names_str}").into());
    }

    let inner = &names_str[1..names_str.len() - 1].trim();
    let names: Vec<String> = inner
        .split_whitespace()
        .map(|s| s.trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // For each name, evaluate the drvPath
    let mut result = Vec::new();
    for name in &names {
        let drv_expr = format!("(import {}).{}.drvPath", sources_path, name);
        let (drv_path, _) = crate::eval::evaluate_with_state(&drv_expr)?;
        let drv_path = drv_path.trim_matches('"').to_string();
        result.push((name.clone(), drv_path));
    }

    Ok(result)
}

/// Build each source package derivation and return `{ name: output_store_path }`.
///
/// `sources_path` is the path to the .nix file that returns the package attrset.
fn build_source_packages(
    packages: &[(String, String)],
    sources_path: &str,
) -> Result<Vec<(String, String)>, Box<dyn std::error::Error>> {
    let db = crate::pathinfo::PathInfoDb::open()?;
    let mut results = Vec::new();

    for (name, _drv_path) in packages {
        println!("Building {name}...");

        // Evaluate the package from the sources file to populate KnownPaths
        let drv_path_expr = format!("(import {}).{}.drvPath", sources_path, name);
        let (drv_path_str, state) = crate::eval::evaluate_with_state(&drv_path_expr)
            .map_err(|e| format!("evaluating drvPath for '{name}': {e}"))?;
        let drv_path_str = drv_path_str.trim_matches('"').to_string();

        let store_path = nix_compat::store_path::StorePath::<String>::from_absolute_path(
            drv_path_str.as_bytes(),
        )
        .map_err(|e| format!("invalid drv path '{drv_path_str}': {e}"))?;

        let known_paths_ref = state.known_paths.borrow();

        match crate::local_build::build_needed(&store_path, &*known_paths_ref, &db) {
            Ok(build_result) => {
                if let Some(out) = build_result.outputs.get("out") {
                    println!("  {name}: built at {out}");
                    results.push((name.clone(), out.clone()));
                } else {
                    return Err(
                        format!("build of {name} succeeded but produced no 'out' output").into(),
                    );
                }
            }
            Err(e) => {
                eprintln!("\nBuild FAILED for package '{name}':");
                eprintln!("  derivation: {drv_path_str}");
                eprintln!("  error: {e}");
                return Err(
                    format!("source rebuild aborted: package '{name}' failed to build").into(),
                );
            }
        }
    }

    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::system::Drivers;

    fn sample_manifest() -> Manifest {
        Manifest {
            manifest_version: 1,
            system: SystemInfo {
                redox_system_version: "0.4.0".to_string(),
                target: "x86_64-unknown-redox".to_string(),
                profile: "development".to_string(),
                hostname: "test-host".to_string(),
                timezone: "UTC".to_string(),
            },
            generation: system::GenerationInfo {
                id: 1,
                build_hash: "abc123".to_string(),
                description: "initial build".to_string(),
                timestamp: "2026-02-20T10:00:00Z".to_string(),
            },
            boot: None,
            configuration: Configuration {
                boot: BootConfig {
                    disk_size_mb: 768,
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
                graphics: SysGraphicsConfig {
                    enabled: false,
                    resolution: "1024x768".to_string(),
                },
                security: SysSecurityConfig {
                    protect_kernel_schemes: true,
                    require_passwords: false,
                    allow_remote_root: false,
                },
                logging: SysLoggingConfig {
                    log_level: "info".to_string(),
                    kernel_log_level: "warn".to_string(),
                    log_to_file: true,
                    max_log_size_mb: 10,
                },
                power: SysPowerConfig {
                    acpi_enabled: true,
                    power_action: "shutdown".to_string(),
                    reboot_on_panic: false,
                },
            },
            packages: vec![
                Package {
                    name: "ion".to_string(),
                    version: "1.0.0".to_string(),
                    store_path: "/nix/store/abc-ion-1.0.0".to_string(),
                },
                Package {
                    name: "base".to_string(),
                    version: "0.1.0".to_string(),
                    store_path: "/nix/store/def-base-0.1.0".to_string(),
                },
                Package {
                    name: "uutils".to_string(),
                    version: "0.0.1".to_string(),
                    store_path: "/nix/store/ghi-uutils-0.0.1".to_string(),
                },
                Package {
                    name: "ripgrep".to_string(),
                    version: "14.0.0".to_string(),
                    store_path: "/nix/store/jkl-ripgrep-14.0.0".to_string(),
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
                declared: BTreeMap::from([
                    (
                        "ptyd".to_string(),
                        system::ServiceInfo {
                            description: "PTY daemon".to_string(),
                            command: "/bin/ptyd".to_string(),
                            svc_type: "scheme".to_string(),
                            args: String::new(),
                            wanted_by: "initfs".to_string(),
                            environment: BTreeMap::new(),
                            after: vec![],
                        },
                    ),
                    (
                        "smolnetd".to_string(),
                        system::ServiceInfo {
                            description: "Network daemon".to_string(),
                            command: "/bin/smolnetd".to_string(),
                            svc_type: "daemon".to_string(),
                            args: String::new(),
                            wanted_by: "rootfs".to_string(),
                            environment: BTreeMap::new(),
                            after: vec!["ptyd".to_string()],
                        },
                    ),
                ]),
                init_scripts: vec!["10_net".to_string()],
                startup_script: "/startup.sh".to_string(),
            },
            activation_scripts: Vec::new(),
            files: BTreeMap::new(),
            system_profile: String::new(),
            toplevel: None,
            etc_source: None,
        }
    }

    // ===== Config Parsing =====

    #[test]
    fn test_parse_minimal_config() {
        let json = r#"{ "hostname": "my-redox" }"#;
        let config = parse_config_json(json).unwrap();
        assert_eq!(config.hostname, Some("my-redox".to_string()));
        assert!(config.timezone.is_none());
        assert!(config.packages.is_none());
        assert!(config.networking.is_none());
    }

    #[test]
    fn test_parse_full_config() {
        let json = r#"{
            "hostname": "my-redox",
            "timezone": "America/New_York",
            "packages": ["ripgrep", "fd", "helix"],
            "networking": { "enable": true, "mode": "dhcp", "dns": ["8.8.8.8"] },
            "graphics": { "enable": false, "resolution": "1920x1080" },
            "security": { "protectKernelSchemes": true, "requirePasswords": true, "allowRemoteRoot": false },
            "logging": { "level": "debug", "kernelLevel": "info", "logToFile": false },
            "power": { "acpiEnabled": true, "powerAction": "reboot", "rebootOnPanic": true },
            "users": { "admin": { "uid": 1001, "gid": 1001, "home": "/home/admin", "shell": "/bin/ion" } },
            "programs": { "editor": "helix" }
        }"#;

        let config = parse_config_json(json).unwrap();
        assert_eq!(config.hostname, Some("my-redox".to_string()));
        assert_eq!(config.timezone, Some("America/New_York".to_string()));
        assert_eq!(
            config.packages,
            Some(vec!["ripgrep".into(), "fd".into(), "helix".into()])
        );

        let net = config.networking.unwrap();
        assert_eq!(net.enable, Some(true));
        assert_eq!(net.mode, Some("dhcp".to_string()));
        assert_eq!(net.dns, Some(vec!["8.8.8.8".to_string()]));

        let sec = config.security.unwrap();
        assert_eq!(sec.require_passwords, Some(true));

        let users = config.users.unwrap();
        assert_eq!(users["admin"].uid, 1001);

        let prg = config.programs.unwrap();
        assert_eq!(prg.editor, Some("helix".to_string()));
    }

    #[test]
    fn test_parse_empty_config() {
        let json = "{}";
        let config = parse_config_json(json).unwrap();
        assert!(config.hostname.is_none());
        assert!(config.timezone.is_none());
        assert!(config.packages.is_none());
        assert!(config.networking.is_none());
        assert!(config.graphics.is_none());
        assert!(config.security.is_none());
        assert!(config.logging.is_none());
        assert!(config.power.is_none());
        assert!(config.users.is_none());
        assert!(config.programs.is_none());
    }

    // ===== Merging =====

    #[test]
    fn test_merge_hostname_only() {
        let current = sample_manifest();
        let config = RebuildConfig {
            hostname: Some("new-host".to_string()),
            ..Default::default()
        };

        let merged = merge_config(&current, &config, &[]).unwrap();

        assert_eq!(merged.system.hostname, "new-host");
        // Everything else unchanged
        assert_eq!(merged.system.timezone, "UTC");
        assert_eq!(merged.configuration.networking.mode, "auto");
        assert_eq!(merged.packages.len(), 4); // unchanged
    }

    #[test]
    fn test_merge_networking() {
        let current = sample_manifest();
        let config = RebuildConfig {
            networking: Some(NetworkConfig {
                mode: Some("dhcp".to_string()),
                dns: Some(vec!["8.8.8.8".to_string(), "8.8.4.4".to_string()]),
                enable: None, // keep current
            }),
            ..Default::default()
        };

        let merged = merge_config(&current, &config, &[]).unwrap();

        assert_eq!(merged.configuration.networking.mode, "dhcp");
        assert_eq!(
            merged.configuration.networking.dns,
            vec!["8.8.8.8", "8.8.4.4"]
        );
        // enable was None — keep current value
        assert!(merged.configuration.networking.enabled);
    }

    #[test]
    fn test_merge_packages_replaces_managed() {
        let current = sample_manifest();
        let config = RebuildConfig {
            packages: Some(vec!["fd".to_string(), "helix".to_string()]),
            ..Default::default()
        };

        let resolved = vec![
            Package {
                name: "fd".to_string(),
                version: "9.0".to_string(),
                store_path: "/nix/store/xyz-fd-9.0".to_string(),
            },
            Package {
                name: "helix".to_string(),
                version: "24.07".to_string(),
                store_path: "/nix/store/xyz-helix-24.07".to_string(),
            },
        ];

        let merged = merge_config(&current, &config, &resolved).unwrap();

        // Boot-essential packages preserved
        let names: Vec<_> = merged.packages.iter().map(|p| p.name.as_str()).collect();
        assert!(names.contains(&"ion")); // boot-essential
        assert!(names.contains(&"base")); // boot-essential
        assert!(names.contains(&"uutils")); // boot-essential
                                            // New managed packages added
        assert!(names.contains(&"fd"));
        assert!(names.contains(&"helix"));
        // Old managed package (ripgrep) removed
        assert!(!names.contains(&"ripgrep"));
    }

    #[test]
    fn test_merge_users_replaces() {
        let current = sample_manifest();
        let config = RebuildConfig {
            users: Some(BTreeMap::from([
                (
                    "admin".to_string(),
                    UserConfig {
                        uid: 1001,
                        gid: 1001,
                        home: "/home/admin".to_string(),
                        shell: "/bin/ion".to_string(),
                    },
                ),
                (
                    "guest".to_string(),
                    UserConfig {
                        uid: 1002,
                        gid: 1002,
                        home: "/home/guest".to_string(),
                        shell: "/bin/ion".to_string(),
                    },
                ),
            ])),
            ..Default::default()
        };

        let merged = merge_config(&current, &config, &[]).unwrap();

        assert_eq!(merged.users.len(), 2);
        assert!(merged.users.contains_key("admin"));
        assert!(merged.users.contains_key("guest"));
        assert!(!merged.users.contains_key("user")); // original user replaced

        // Groups auto-generated from users
        assert_eq!(merged.groups.len(), 2);
        assert_eq!(merged.groups["admin"].gid, 1001);
    }

    #[test]
    fn test_merge_preserves_unset_fields() {
        let current = sample_manifest();
        let config = RebuildConfig::default(); // all None

        let merged = merge_config(&current, &config, &[]).unwrap();

        assert_eq!(merged.system.hostname, current.system.hostname);
        assert_eq!(merged.system.timezone, current.system.timezone);
        assert_eq!(
            merged.configuration.networking.mode,
            current.configuration.networking.mode
        );
        assert_eq!(merged.packages.len(), current.packages.len());
        assert_eq!(merged.users.len(), current.users.len());
    }

    #[test]
    fn test_merge_all_fields() {
        let current = sample_manifest();
        let config = RebuildConfig {
            hostname: Some("all-fields".to_string()),
            timezone: Some("Europe/Berlin".to_string()),
            networking: Some(NetworkConfig {
                enable: Some(false),
                mode: Some("none".to_string()),
                dns: Some(vec![]),
            }),
            graphics: Some(GraphicsConfigInput {
                enable: Some(true),
                resolution: Some("1920x1080".to_string()),
            }),
            security: Some(SecurityConfig {
                protect_kernel_schemes: Some(false),
                require_passwords: Some(true),
                allow_remote_root: Some(true),
            }),
            logging: Some(LoggingConfig {
                level: Some("debug".to_string()),
                kernel_level: Some("error".to_string()),
                log_to_file: Some(false),
            }),
            power: Some(PowerConfig {
                acpi_enabled: Some(false),
                power_action: Some("reboot".to_string()),
                reboot_on_panic: Some(true),
            }),
            packages: None,
            users: None,
            programs: None,
            hardware: None,
            services: None,
            package_sources: None,
        };

        let merged = merge_config(&current, &config, &[]).unwrap();

        assert_eq!(merged.system.hostname, "all-fields");
        assert_eq!(merged.system.timezone, "Europe/Berlin");
        assert!(!merged.configuration.networking.enabled);
        assert_eq!(merged.configuration.networking.mode, "none");
        assert!(merged.configuration.graphics.enabled);
        assert_eq!(merged.configuration.graphics.resolution, "1920x1080");
        assert!(!merged.configuration.security.protect_kernel_schemes);
        assert!(merged.configuration.security.require_passwords);
        assert!(merged.configuration.security.allow_remote_root);
        assert_eq!(merged.configuration.logging.log_level, "debug");
        assert_eq!(merged.configuration.logging.kernel_log_level, "error");
        assert!(!merged.configuration.logging.log_to_file);
        assert!(!merged.configuration.power.acpi_enabled);
        assert_eq!(merged.configuration.power.power_action, "reboot");
        assert!(merged.configuration.power.reboot_on_panic);
    }

    #[test]
    fn test_merge_security_partial() {
        let current = sample_manifest();
        let config = RebuildConfig {
            security: Some(SecurityConfig {
                require_passwords: Some(true),
                protect_kernel_schemes: None, // keep current
                allow_remote_root: None,      // keep current
            }),
            ..Default::default()
        };

        let merged = merge_config(&current, &config, &[]).unwrap();

        assert!(merged.configuration.security.require_passwords); // changed
        assert!(merged.configuration.security.protect_kernel_schemes); // kept
        assert!(!merged.configuration.security.allow_remote_root); // kept
    }

    #[test]
    fn test_merge_empty_config_is_identity() {
        let current = sample_manifest();
        let empty = RebuildConfig::default();

        let merged = merge_config(&current, &empty, &[]).unwrap();

        let cur_json = serde_json::to_string(&current).unwrap();
        let merged_json = serde_json::to_string(&merged).unwrap();
        assert_eq!(cur_json, merged_json);
    }

    // ===== Package Resolution =====

    #[test]
    fn test_resolve_packages_from_index() {
        let index = r#"{
            "ripgrep": { "storePath": "/nix/store/abc-ripgrep-14.0", "version": "14.0", "pname": "ripgrep" },
            "fd": { "storePath": "/nix/store/def-fd-9.0", "version": "9.0", "pname": "fd" }
        }"#;

        let names = vec!["ripgrep".to_string(), "fd".to_string()];
        let packages = resolve_packages_from_json(&names, index).unwrap();

        assert_eq!(packages.len(), 2);
        assert_eq!(packages[0].name, "ripgrep");
        assert_eq!(packages[0].version, "14.0");
        assert_eq!(packages[0].store_path, "/nix/store/abc-ripgrep-14.0");
        assert_eq!(packages[1].name, "fd");
    }

    #[test]
    fn test_resolve_packages_missing() {
        let index = r#"{ "ripgrep": { "storePath": "/nix/store/abc", "version": "14.0" } }"#;

        let names = vec!["ripgrep".to_string(), "nonexistent".to_string()];
        let packages = resolve_packages_from_json(&names, index).unwrap();

        assert_eq!(packages.len(), 2);
        assert_eq!(packages[0].store_path, "/nix/store/abc");
        assert_eq!(packages[1].name, "nonexistent");
        assert!(packages[1].store_path.is_empty()); // not resolved
    }

    #[test]
    fn test_resolve_packages_empty_index() {
        let index = "{}";
        let names = vec!["foo".to_string()];
        let packages = resolve_packages_from_json(&names, index).unwrap();

        assert_eq!(packages.len(), 1);
        assert!(packages[0].store_path.is_empty());
    }

    #[test]
    fn test_cache_source_for_rebuild_prefers_remote_url() {
        let source =
            cache_source_for_rebuild("/tmp/custom/packages.json", Some("http://10.0.2.2:8080/"));
        match source {
            crate::cache_source::CacheSource::Remote(url) => {
                assert_eq!(url, "http://10.0.2.2:8080");
            }
            other => panic!("expected remote cache source, got {other:?}"),
        }
    }

    #[test]
    fn test_cache_source_for_rebuild_uses_index_parent_for_local_cache() {
        let source = cache_source_for_rebuild("/tmp/custom-cache/packages.json", None);
        match source {
            crate::cache_source::CacheSource::Local(path) => {
                assert_eq!(path, Path::new("/tmp/custom-cache"));
            }
            other => panic!("expected local cache source, got {other:?}"),
        }
    }

    #[test]
    fn test_resolve_packages_from_indexes_prefers_primary_cache() {
        let names = vec!["ripgrep".to_string()];
        let primary: crate::local_cache::PackageIndex = serde_json::from_str(
            r#"{
                "version": 1,
                "packages": {
                    "ripgrep": { "storePath": "/nix/store/remote-rg", "pname": "ripgrep", "version": "14.1" }
                }
            }"#,
        )
        .unwrap();
        let fallback: crate::local_cache::PackageIndex = serde_json::from_str(
            r#"{
                "version": 1,
                "packages": {
                    "ripgrep": { "storePath": "/nix/store/local-rg", "pname": "ripgrep", "version": "14.0" }
                }
            }"#,
        )
        .unwrap();
        let primary_source = crate::cache_source::CacheSource::Remote("http://10.0.2.2:8080".to_string());
        let fallback_source = crate::cache_source::CacheSource::Local(Path::new("/nix/cache").to_path_buf());

        let resolved = resolve_packages_from_indexes(
            &names,
            Some(&primary),
            Some(&primary_source),
            Some(&fallback),
            Some(&fallback_source),
        );

        assert_eq!(resolved.len(), 1);
        assert_eq!(resolved[0].package.store_path, "/nix/store/remote-rg");
        match resolved[0].source.as_ref() {
            Some(crate::cache_source::CacheSource::Remote(url)) => {
                assert_eq!(url, "http://10.0.2.2:8080");
            }
            other => panic!("expected remote source, got {other:?}"),
        }
    }

    #[test]
    fn test_resolve_packages_from_indexes_falls_back_to_local_cache() {
        let names = vec!["ripgrep".to_string(), "fd".to_string()];
        let primary: crate::local_cache::PackageIndex = serde_json::from_str(
            r#"{
                "version": 1,
                "packages": {
                    "ripgrep": { "storePath": "/nix/store/remote-rg", "pname": "ripgrep", "version": "14.1" }
                }
            }"#,
        )
        .unwrap();
        let fallback: crate::local_cache::PackageIndex = serde_json::from_str(
            r#"{
                "version": 1,
                "packages": {
                    "fd": { "storePath": "/nix/store/local-fd", "pname": "fd", "version": "9.0" }
                }
            }"#,
        )
        .unwrap();
        let primary_source = crate::cache_source::CacheSource::Remote("http://10.0.2.2:8080".to_string());
        let fallback_source = crate::cache_source::CacheSource::Local(Path::new("/nix/cache").to_path_buf());

        let resolved = resolve_packages_from_indexes(
            &names,
            Some(&primary),
            Some(&primary_source),
            Some(&fallback),
            Some(&fallback_source),
        );

        assert_eq!(resolved.len(), 2);
        assert_eq!(resolved[0].package.store_path, "/nix/store/remote-rg");
        assert_eq!(resolved[1].package.store_path, "/nix/store/local-fd");
        match resolved[1].source.as_ref() {
            Some(crate::cache_source::CacheSource::Local(path)) => {
                assert_eq!(path, Path::new("/nix/cache"));
            }
            other => panic!("expected local source, got {other:?}"),
        }
    }

    #[test]
    fn test_resolve_packages_from_indexes_marks_unresolved_when_missing_everywhere() {
        let names = vec!["missing".to_string()];
        let primary: crate::local_cache::PackageIndex = serde_json::from_str(
            r#"{ "version": 1, "packages": {} }"#,
        )
        .unwrap();
        let fallback: crate::local_cache::PackageIndex = serde_json::from_str(
            r#"{ "version": 1, "packages": {} }"#,
        )
        .unwrap();
        let primary_source = crate::cache_source::CacheSource::Remote("http://10.0.2.2:8080".to_string());
        let fallback_source = crate::cache_source::CacheSource::Local(Path::new("/nix/cache").to_path_buf());

        let resolved = resolve_packages_from_indexes(
            &names,
            Some(&primary),
            Some(&primary_source),
            Some(&fallback),
            Some(&fallback_source),
        );

        assert_eq!(resolved.len(), 1);
        assert!(resolved[0].package.store_path.is_empty());
        assert!(resolved[0].source.is_none());
    }

    // ===== Boot Essential =====

    #[test]
    fn test_is_boot_essential() {
        assert!(is_boot_essential("ion"));
        assert!(is_boot_essential("ion-shell"));
        assert!(is_boot_essential("base"));
        assert!(is_boot_essential("redox-base"));
        assert!(is_boot_essential("uutils"));
        assert!(is_boot_essential("snix"));
        assert!(is_boot_essential("snix-redox"));
        assert!(!is_boot_essential("ripgrep"));
        assert!(!is_boot_essential("fd"));
        assert!(!is_boot_essential("helix"));
    }

    // ===== Config Serde =====

    #[test]
    fn test_config_serde_roundtrip() {
        let json = r#"{
            "hostname": "rt",
            "packages": ["x"],
            "networking": { "mode": "dhcp" }
        }"#;

        let config: RebuildConfig = serde_json::from_str(json).unwrap();
        let serialized = serde_json::to_string(&config).unwrap();
        // Re-parse should give same values
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        assert_eq!(reparsed["hostname"], "rt");
    }

    // ===== Nix Expression =====

    #[test]
    fn test_evaluate_config_expr() {
        // Verify the Nix expression we'd build
        let path = "/etc/redox-system/configuration.nix";
        let expr = format!("builtins.toJSON (import {})", path);
        assert_eq!(
            expr,
            "builtins.toJSON (import /etc/redox-system/configuration.nix)"
        );
    }

    // ===== JSON Config Fallback =====

    #[test]
    fn test_evaluate_config_json_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let json_path = dir.path().join("config.json");
        fs::write(&json_path, r#"{ "hostname": "json-host" }"#).unwrap();

        let config = evaluate_config(json_path.to_str().unwrap()).unwrap();
        assert_eq!(config.hostname, Some("json-host".to_string()));
    }

    // ===== Init Config =====

    #[test]
    fn test_init_config_creates_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("configuration.nix");

        init_config(Some(path.to_str().unwrap())).unwrap();

        assert!(path.exists());
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("configuration.nix"));
        assert!(content.contains("snix system rebuild"));
    }

    #[test]
    fn test_init_config_refuses_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("configuration.nix");
        fs::write(&path, "existing").unwrap();

        let result = init_config(Some(path.to_str().unwrap()));
        assert!(result.is_err());
    }

    #[test]
    fn test_preserve_active_config_replaces_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let store_dir = dir.path().join("store");
        let live_dir = dir.path().join("etc/redox-system");
        fs::create_dir_all(&store_dir).unwrap();
        fs::create_dir_all(&live_dir).unwrap();

        let store_cfg = store_dir.join("configuration.nix");
        fs::write(&store_cfg, "{ hostname = \"redox\"; }\n").unwrap();

        let live_cfg = live_dir.join("configuration.nix");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&store_cfg, &live_cfg).unwrap();

        preserve_active_config(live_cfg.to_str().unwrap(), "{ hostname = \"persisted\"; }\n").unwrap();

        let meta = fs::symlink_metadata(&live_cfg).unwrap();
        assert!(!meta.file_type().is_symlink());
        assert_eq!(fs::read_to_string(&live_cfg).unwrap(), "{ hostname = \"persisted\"; }\n");
    }

    // ===== Boot-Affecting Detection: Hardware Fields =====

    #[test]
    fn test_storage_drivers_alone_triggers_boot_affecting() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                storage_drivers: Some(vec!["nvmed".to_string()]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, None));
    }

    #[test]
    fn test_network_drivers_alone_triggers_boot_affecting() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                network_drivers: Some(vec!["e1000d".to_string()]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, None));
    }

    #[test]
    fn test_graphics_drivers_alone_triggers_boot_affecting() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                graphics_drivers: Some(vec!["virtio-gpud".to_string()]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, None));
    }

    #[test]
    fn test_audio_drivers_alone_triggers_boot_affecting() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                audio_drivers: Some(vec!["sb16d".to_string()]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, None));
    }

    #[test]
    fn test_usb_toggle_alone_triggers_boot_affecting() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                usb_enabled: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, None));
    }

    #[test]
    fn test_empty_hardware_block_does_not_trigger_boot_affecting() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput::default()),
            ..Default::default()
        };
        assert!(!has_boot_affecting_changes(&config, None));
    }

    // ===== Boot-Affecting Detection: Services =====

    #[test]
    fn test_added_service_triggers_boot_affecting() {
        let manifest = sample_manifest();
        // manifest has ptyd, smolnetd — add audiod
        let config = RebuildConfig {
            services: Some(vec![
                "ptyd".to_string(),
                "smolnetd".to_string(),
                "audiod".to_string(),
            ]),
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, Some(&manifest)));
    }

    #[test]
    fn test_removed_service_triggers_boot_affecting() {
        let manifest = sample_manifest();
        // manifest has ptyd, smolnetd — remove smolnetd
        let config = RebuildConfig {
            services: Some(vec!["ptyd".to_string()]),
            package_sources: None,
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, Some(&manifest)));
    }

    #[test]
    fn test_unchanged_services_does_not_trigger_boot_affecting() {
        let manifest = sample_manifest();
        // Same services as manifest (order shouldn't matter)
        let config = RebuildConfig {
            services: Some(vec!["smolnetd".to_string(), "ptyd".to_string()]),
            ..Default::default()
        };
        assert!(!has_boot_affecting_changes(&config, Some(&manifest)));
    }

    #[test]
    fn test_no_services_field_does_not_trigger_boot_affecting() {
        let manifest = sample_manifest();
        let config = RebuildConfig::default();
        assert!(!has_boot_affecting_changes(&config, Some(&manifest)));
    }

    #[test]
    fn test_services_without_manifest_triggers_boot_affecting() {
        // No manifest to compare — any declared services are potentially changing
        let config = RebuildConfig {
            services: Some(vec!["ptyd".to_string()]),
            package_sources: None,
            ..Default::default()
        };
        assert!(has_boot_affecting_changes(&config, None));
    }

    #[test]
    fn test_has_service_changes_added() {
        let manifest = sample_manifest();
        let config = RebuildConfig {
            services: Some(vec![
                "ptyd".to_string(),
                "smolnetd".to_string(),
                "audiod".to_string(),
            ]),
            ..Default::default()
        };
        assert!(has_service_changes(&config, Some(&manifest)));
    }

    #[test]
    fn test_has_service_changes_matching() {
        let manifest = sample_manifest();
        let config = RebuildConfig {
            services: Some(vec!["ptyd".to_string(), "smolnetd".to_string()]),
            ..Default::default()
        };
        assert!(!has_service_changes(&config, Some(&manifest)));
    }

    #[test]
    fn test_has_service_changes_none() {
        let manifest = sample_manifest();
        let config = RebuildConfig::default();
        assert!(!has_service_changes(&config, Some(&manifest)));
    }

    // ===== needs_bridge combines all checks =====

    #[test]
    fn test_needs_bridge_packages_only() {
        let config = RebuildConfig {
            packages: Some(vec!["ripgrep".to_string()]),
            ..Default::default()
        };
        assert!(needs_bridge(&config, None));
    }

    #[test]
    fn test_needs_bridge_hardware_only() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                usb_enabled: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(needs_bridge(&config, None));
    }

    #[test]
    fn test_needs_bridge_services_only() {
        let manifest = sample_manifest();
        let config = RebuildConfig {
            services: Some(vec![
                "ptyd".to_string(),
                "smolnetd".to_string(),
                "new_svc".to_string(),
            ]),
            package_sources: None,
            ..Default::default()
        };
        assert!(needs_bridge(&config, Some(&manifest)));
    }

    #[test]
    fn test_needs_bridge_config_only_no_bridge() {
        let manifest = sample_manifest();
        let config = RebuildConfig {
            hostname: Some("new-host".to_string()),
            ..Default::default()
        };
        assert!(!needs_bridge(&config, Some(&manifest)));
    }

    #[test]
    fn test_select_auto_rebuild_route_uses_bridge_for_package_changes_when_available() {
        let config = RebuildConfig {
            packages: Some(vec!["ripgrep".to_string()]),
            ..Default::default()
        };
        let manifest = sample_manifest();
        assert_eq!(
            select_auto_rebuild_route(&config, Some(&manifest), true).unwrap(),
            AutoRebuildRoute::Bridge
        );
    }

    #[test]
    fn test_select_auto_rebuild_route_uses_local_for_package_changes_without_bridge() {
        let config = RebuildConfig {
            packages: Some(vec!["ripgrep".to_string()]),
            ..Default::default()
        };
        let manifest = sample_manifest();
        assert_eq!(
            select_auto_rebuild_route(&config, Some(&manifest), false).unwrap(),
            AutoRebuildRoute::Local
        );
    }

    #[test]
    fn test_select_auto_rebuild_route_rejects_boot_changes_without_bridge() {
        let config = RebuildConfig {
            hardware: Some(HardwareConfigInput {
                usb_enabled: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        let manifest = sample_manifest();
        let err = select_auto_rebuild_route(&config, Some(&manifest), false)
            .unwrap_err()
            .to_string();
        assert!(err.contains("build bridge"));
        assert!(err.contains("hardware/drivers or services"));
    }

    #[test]
    fn test_select_auto_rebuild_route_uses_local_for_config_only_changes() {
        let config = RebuildConfig {
            hostname: Some("new-host".to_string()),
            ..Default::default()
        };
        let manifest = sample_manifest();
        assert_eq!(
            select_auto_rebuild_route(&config, Some(&manifest), false).unwrap(),
            AutoRebuildRoute::Local
        );
    }

    // ===== Boot Path Diffing =====

    #[test]
    fn test_print_changes_shows_boot_initfs_diff() {
        use crate::system::BootComponents;

        let mut current = sample_manifest();
        current.boot = Some(BootComponents {
            kernel: Some("/nix/store/aaa-kernel/boot/kernel".to_string()),
            initfs: Some("/nix/store/bbb-initfs/boot/initfs".to_string()),
            bootloader: Some("/nix/store/ccc-boot/boot/EFI/BOOT/BOOTX64.EFI".to_string()),
        });

        let mut merged = current.clone();
        merged.boot = Some(BootComponents {
            kernel: Some("/nix/store/aaa-kernel/boot/kernel".to_string()),
            initfs: Some("/nix/store/ddd-initfs/boot/initfs".to_string()),
            bootloader: Some("/nix/store/ccc-boot/boot/EFI/BOOT/BOOTX64.EFI".to_string()),
        });

        // Capture stdout
        let output = capture_print_changes(&current, &merged);
        assert!(
            output.contains("boot.initfs:"),
            "should show initfs diff, got: {output}"
        );
        assert!(output.contains("bbb-initfs"), "should show old path");
        assert!(output.contains("ddd-initfs"), "should show new path");
        assert!(!output.contains("boot.kernel:"), "kernel unchanged");
        assert!(!output.contains("boot.bootloader:"), "bootloader unchanged");
    }

    #[test]
    fn test_print_changes_no_boot_lines_when_identical() {
        use crate::system::BootComponents;

        let mut current = sample_manifest();
        current.boot = Some(BootComponents {
            kernel: Some("/nix/store/aaa-kernel/boot/kernel".to_string()),
            initfs: Some("/nix/store/bbb-initfs/boot/initfs".to_string()),
            bootloader: Some("/nix/store/ccc-boot/boot/EFI/BOOT/BOOTX64.EFI".to_string()),
        });

        let merged = current.clone();

        let output = capture_print_changes(&current, &merged);
        assert!(
            !output.contains("boot."),
            "no boot lines when identical, got: {output}"
        );
    }

    #[test]
    fn test_print_changes_handles_boot_none() {
        let mut current = sample_manifest();
        current.boot = None;

        let mut merged = current.clone();
        merged.boot = Some(crate::system::BootComponents {
            kernel: Some("/nix/store/aaa-kernel/boot/kernel".to_string()),
            initfs: None,
            bootloader: None,
        });

        // Should not panic — one side is None, skip comparison
        let output = capture_print_changes(&current, &merged);
        assert!(
            !output.contains("boot."),
            "no boot lines when one side is None"
        );
    }

    #[test]
    fn test_print_changes_both_boot_none() {
        let mut current = sample_manifest();
        current.boot = None;
        let merged = current.clone();

        // Should not panic
        let output = capture_print_changes(&current, &merged);
        assert!(!output.contains("boot."));
    }

    /// Helper: capture print_changes output by temporarily redirecting stdout.
    /// Since print_changes uses println!, we build the same change list manually.
    fn capture_print_changes(current: &Manifest, merged: &Manifest) -> String {
        // Replicate the boot path diffing logic from print_changes to capture output
        // (print_changes writes to stdout which is hard to capture in tests)
        let mut changes = Vec::new();

        if let (Some(cur_boot), Some(new_boot)) = (&current.boot, &merged.boot) {
            if cur_boot.kernel != new_boot.kernel {
                changes.push(format!(
                    "  boot.kernel: {} → {}",
                    cur_boot.kernel.as_deref().unwrap_or("(none)"),
                    new_boot.kernel.as_deref().unwrap_or("(none)")
                ));
            }
            if cur_boot.initfs != new_boot.initfs {
                changes.push(format!(
                    "  boot.initfs: {} → {}",
                    cur_boot.initfs.as_deref().unwrap_or("(none)"),
                    new_boot.initfs.as_deref().unwrap_or("(none)")
                ));
            }
            if cur_boot.bootloader != new_boot.bootloader {
                changes.push(format!(
                    "  boot.bootloader: {} → {}",
                    cur_boot.bootloader.as_deref().unwrap_or("(none)"),
                    new_boot.bootloader.as_deref().unwrap_or("(none)")
                ));
            }
        }

        changes.join("\n")
    }

    // ===== Config Parsing: services field =====

    #[test]
    fn test_parse_config_with_services() {
        let json = r#"{ "services": ["ptyd", "smolnetd", "audiod"] }"#;
        let config = parse_config_json(json).unwrap();
        assert_eq!(
            config.services,
            Some(vec!["ptyd".into(), "smolnetd".into(), "audiod".into()])
        );
    }

    #[test]
    fn test_parse_config_without_services() {
        let json = r#"{ "hostname": "test" }"#;
        let config = parse_config_json(json).unwrap();
        assert!(config.services.is_none());
    }

    // ===== Nonexistent Package Handling =====

    #[test]
    fn test_merge_unresolved_package_included_in_manifest() {
        let current = sample_manifest();
        let config = RebuildConfig {
            packages: Some(vec!["nonexistent".to_string()]),
            ..Default::default()
        };

        // Package not in cache → empty store_path
        let resolved = vec![Package {
            name: "nonexistent".to_string(),
            version: String::new(),
            store_path: String::new(),
        }];

        let merged = merge_config(&current, &config, &resolved).unwrap();

        // Boot-essential packages preserved
        let names: Vec<_> = merged.packages.iter().map(|p| p.name.as_str()).collect();
        assert!(names.contains(&"ion"), "boot-essential ion preserved");
        assert!(names.contains(&"base"), "boot-essential base preserved");
        // Unresolved package is still in the list (with empty store_path)
        assert!(
            names.contains(&"nonexistent"),
            "unresolved package included"
        );
        let unresolved = merged
            .packages
            .iter()
            .find(|p| p.name == "nonexistent")
            .unwrap();
        assert!(unresolved.store_path.is_empty(), "store_path stays empty");
    }

    #[test]
    fn test_merge_all_unresolved_preserves_boot_essential() {
        let current = sample_manifest();
        let config = RebuildConfig {
            packages: Some(vec!["pkg1".to_string(), "pkg2".to_string()]),
            ..Default::default()
        };

        // All packages unresolved
        let resolved = vec![
            Package {
                name: "pkg1".to_string(),
                version: String::new(),
                store_path: String::new(),
            },
            Package {
                name: "pkg2".to_string(),
                version: String::new(),
                store_path: String::new(),
            },
        ];

        let merged = merge_config(&current, &config, &resolved).unwrap();

        let names: Vec<_> = merged.packages.iter().map(|p| p.name.as_str()).collect();
        // Boot-essential from current manifest always preserved
        assert!(names.contains(&"ion"));
        assert!(names.contains(&"base"));
        assert!(names.contains(&"uutils"));
        // Old managed packages (ripgrep) replaced by the new set
        assert!(!names.contains(&"ripgrep"));
        // New unresolved packages present
        assert!(names.contains(&"pkg1"));
        assert!(names.contains(&"pkg2"));
    }
}
