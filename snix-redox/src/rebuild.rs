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
    LoggingConfig as SysLoggingConfig, Manifest, NetworkingConfig, Package, PowerConfig as SysPowerConfig,
    SecurityConfig as SysSecurityConfig, Services, SystemInfo, User,
};

const DEFAULT_CONFIG_PATH: &str = "/etc/redox-system/configuration.nix";
const DEFAULT_MANIFEST_PATH: &str = "/etc/redox-system/manifest.json";
const DEFAULT_CACHE_INDEX: &str = "/nix/cache/packages.json";

/// Boot-essential package names that are always preserved in /bin/.
const BOOT_ESSENTIAL: &[&str] = &[
    "ion", "ion-shell",
    "base", "redox-base",
    "init", "logd", "ramfs", "zerod", "nulld", "randd",
    "snix", "snix-redox",
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

// ===== Public API =====

/// Rebuild the system from configuration.nix.
///
/// Evaluates the Nix config, merges with the current manifest, resolves
/// packages, and switches to the new configuration.
pub fn rebuild(
    config_path: Option<&str>,
    dry_run: bool,
    manifest_path: Option<&str>,
    gen_dir: Option<&str>,
    cache_index_path: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let cfg_path = config_path.unwrap_or(DEFAULT_CONFIG_PATH);
    let mpath = manifest_path.unwrap_or(DEFAULT_MANIFEST_PATH);
    let cache_path = cache_index_path.unwrap_or(DEFAULT_CACHE_INDEX);

    // Step 1: Evaluate configuration.nix
    println!("Evaluating {cfg_path}...");
    let config = evaluate_config(cfg_path)?;

    // Step 2: Load current manifest
    let current = system::load_manifest_from(mpath)?;

    // Step 3: Resolve package names → store paths
    let resolved_packages = resolve_packages(&config.packages, cache_path)?;

    // Step 4: Merge config into manifest
    let merged = merge_config(&current, &config, &resolved_packages)?;

    // Step 5: Show what would change
    print_changes(&current, &merged, &config);

    if dry_run {
        println!();
        println!("Dry run complete. No changes applied.");
        println!("Edit {cfg_path} and run `snix system rebuild` to apply.");
        return Ok(());
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

    println!();
    println!("✓ System rebuilt from {cfg_path}");

    Ok(())
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
            println!("    {name}: uid={} gid={} home={} shell={}", u.uid, u.gid, u.home, u.shell);
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
        return Err(format!(
            "error evaluating {path}:\n{}",
            errors.join("\n")
        )
        .into());
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

/// Resolve package names to store paths using the binary cache index.
fn resolve_packages(
    names: &Option<Vec<String>>,
    cache_index_path: &str,
) -> Result<Vec<Package>, Box<dyn std::error::Error>> {
    let names = match names {
        Some(n) if !n.is_empty() => n,
        _ => return Ok(Vec::new()),
    };

    let index_json = if Path::new(cache_index_path).exists() {
        fs::read_to_string(cache_index_path)?
    } else {
        eprintln!("warning: package index not found at {cache_index_path}");
        eprintln!("         package names will not be resolved to store paths");
        String::from("{}")
    };

    resolve_packages_from_json(names, &index_json)
}

/// Resolve package names from a JSON index string (testable).
pub(crate) fn resolve_packages_from_json(
    names: &[String],
    index_json: &str,
) -> Result<Vec<Package>, Box<dyn std::error::Error>> {
    // packages.json format: { "name": { "storePath": "...", "version": "...", ... } }
    let index: BTreeMap<String, serde_json::Value> = serde_json::from_str(index_json)?;

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
            current.configuration.networking.enabled,
            merged.configuration.networking.enabled
        ));
    }
    if current.configuration.networking.mode != merged.configuration.networking.mode {
        changes.push(format!(
            "  networking.mode: {} → {}",
            current.configuration.networking.mode,
            merged.configuration.networking.mode
        ));
    }

    // Graphics
    if current.configuration.graphics.enabled != merged.configuration.graphics.enabled {
        changes.push(format!(
            "  graphics.enabled: {} → {}",
            current.configuration.graphics.enabled,
            merged.configuration.graphics.enabled
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
            added.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ")
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
                init_scripts: vec!["10_net".to_string()],
                startup_script: "/startup.sh".to_string(),
            },
            files: BTreeMap::new(),
            system_profile: String::new(),
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
        assert_eq!(config.packages, Some(vec!["ripgrep".into(), "fd".into(), "helix".into()]));

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
}
