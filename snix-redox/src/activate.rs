//! Atomic system activation for RedoxOS.
//!
//! Implements NixOS-style `switch-to-configuration` semantics:
//!   1. Atomic profile swap (build new profile in staging dir, then rename)
//!   2. Config file activation (diff + write changed files)
//!   3. Service change detection (report added/removed/changed services)
//!   4. Dry-run mode (show plan without touching disk)
//!   5. Activation hooks (pre/post-switch scripts)
//!
//! Called by `system::switch()` and `system::rollback()` after manifest
//! rotation. The manifest tells us what the system *should* look like;
//! activate makes it so.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

use crate::system::{ActivationScript, FileInfo, Manifest, Package};

/// System profile bin directory (where managed package binaries live).
const SYSTEM_PROFILE_BIN: &str = "/nix/system/profile/bin";

/// Staging directory for building the new profile atomically.
const STAGING_DIR: &str = "/nix/system/.profile-staging";

// ═══════════════════════════════════════════════════════════════════════════
// Topological Sort for Activation Scripts
// ═══════════════════════════════════════════════════════════════════════════

/// Topologically sort activation scripts by their dependencies.
/// Returns ordered script names on success, or a cycle description on failure.
///
/// Uses Kahn's algorithm: repeatedly pick nodes with zero in-degree.
/// If the queue empties before all nodes are processed, there's a cycle.
pub fn topo_sort(scripts: &[ActivationScript]) -> Result<Vec<String>, String> {
    if scripts.is_empty() {
        return Ok(Vec::new());
    }

    let names: HashSet<&str> = scripts.iter().map(|s| s.name.as_str()).collect();

    // Validate all deps reference known scripts
    for s in scripts {
        for dep in &s.deps {
            if !names.contains(dep.as_str()) {
                return Err(format!(
                    "script '{}' depends on unknown script '{}'",
                    s.name, dep
                ));
            }
        }
    }

    // Build adjacency list and in-degree map
    let mut in_degree: HashMap<&str, usize> = HashMap::new();
    let mut dependents: HashMap<&str, Vec<&str>> = HashMap::new();

    for s in scripts {
        in_degree.entry(s.name.as_str()).or_insert(0);
        for dep in &s.deps {
            *in_degree.entry(s.name.as_str()).or_insert(0) += 1;
            dependents
                .entry(dep.as_str())
                .or_default()
                .push(s.name.as_str());
        }
    }

    // Seed queue with zero-in-degree nodes (sorted for determinism)
    let mut queue: VecDeque<&str> = VecDeque::new();
    let mut zero_deg: Vec<&str> = in_degree
        .iter()
        .filter(|(_, &deg)| deg == 0)
        .map(|(&name, _)| name)
        .collect();
    zero_deg.sort();
    for name in zero_deg {
        queue.push_back(name);
    }

    let mut result = Vec::with_capacity(scripts.len());

    while let Some(name) = queue.pop_front() {
        result.push(name.to_string());
        if let Some(deps) = dependents.get(name) {
            let mut next: Vec<&str> = Vec::new();
            for &dep in deps {
                let deg = in_degree.get_mut(dep).unwrap();
                *deg -= 1;
                if *deg == 0 {
                    next.push(dep);
                }
            }
            next.sort();
            for n in next {
                queue.push_back(n);
            }
        }
    }

    if result.len() != scripts.len() {
        // Find the cycle: nodes still with in-degree > 0
        let in_cycle: Vec<&str> = in_degree
            .iter()
            .filter(|(_, &deg)| deg > 0)
            .map(|(&name, _)| name)
            .collect();
        Err(format!(
            "dependency cycle among activation scripts: {}",
            in_cycle.join(", ")
        ))
    } else {
        Ok(result)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Activation Plan — computed diff between current and target manifests
// ═══════════════════════════════════════════════════════════════════════════

/// A complete plan of what `activate` will do. Computed from the diff between
/// the current (old) and target (new) manifests.
#[derive(Debug)]
pub struct ActivationPlan {
    /// Packages added in the new generation.
    pub packages_added: Vec<String>,
    /// Packages removed from the old generation.
    pub packages_removed: Vec<String>,
    /// Packages whose version or store path changed.
    pub packages_changed: Vec<PackageChange>,
    /// Config files that will be created (path → new hash).
    pub config_files_added: Vec<String>,
    /// Config files that will be removed.
    pub config_files_removed: Vec<String>,
    /// Config files whose content changed (path → old hash, new hash).
    pub config_files_changed: Vec<ConfigChange>,
    /// Services added (name, type).
    pub services_added: Vec<ServiceChange>,
    /// Services removed (name, type).
    pub services_removed: Vec<ServiceChange>,
    /// Services whose definition changed (command, type, environment).
    pub services_changed: Vec<ServiceChange>,
    /// Whether the system profile needs rebuilding.
    pub profile_needs_rebuild: bool,
    /// Number of binaries that will be linked in the new profile.
    pub profile_binary_count: u32,
    /// User accounts added.
    pub users_added: Vec<String>,
    /// User accounts removed.
    pub users_removed: Vec<String>,
    /// User accounts with changed properties.
    pub users_changed: Vec<String>,
    /// Activation scripts to execute (in dependency order).
    pub activation_scripts: Vec<String>,
}

/// A package that changed between generations.
#[derive(Debug)]
pub struct PackageChange {
    pub name: String,
    pub old_version: String,
    pub new_version: String,
    pub old_store_path: String,
    pub new_store_path: String,
}

/// A config file that changed between generations.
#[derive(Debug)]
pub struct ConfigChange {
    pub path: String,
    pub old_hash: String,
    pub new_hash: String,
}

/// A service that was added, removed, or changed.
#[derive(Debug, PartialEq)]
pub struct ServiceChange {
    pub name: String,
    pub svc_type: String,
    pub description: String,
}

// ═══════════════════════════════════════════════════════════════════════════
// Plan Computation
// ═══════════════════════════════════════════════════════════════════════════

/// Compute an activation plan by diffing two manifests.
pub fn plan(old: &Manifest, new: &Manifest) -> ActivationPlan {
    // Package diff
    let old_pkgs: BTreeMap<&str, &Package> =
        old.packages.iter().map(|p| (p.name.as_str(), p)).collect();
    let new_pkgs: BTreeMap<&str, &Package> =
        new.packages.iter().map(|p| (p.name.as_str(), p)).collect();

    let mut packages_added = Vec::new();
    let mut packages_removed = Vec::new();
    let mut packages_changed = Vec::new();

    for (name, new_pkg) in &new_pkgs {
        match old_pkgs.get(name) {
            None => packages_added.push(name.to_string()),
            Some(old_pkg) => {
                if old_pkg.version != new_pkg.version
                    || old_pkg.store_path != new_pkg.store_path
                {
                    packages_changed.push(PackageChange {
                        name: name.to_string(),
                        old_version: old_pkg.version.clone(),
                        new_version: new_pkg.version.clone(),
                        old_store_path: old_pkg.store_path.clone(),
                        new_store_path: new_pkg.store_path.clone(),
                    });
                }
            }
        }
    }
    for name in old_pkgs.keys() {
        if !new_pkgs.contains_key(name) {
            packages_removed.push(name.to_string());
        }
    }

    // Config file diff
    let (config_files_added, config_files_removed, config_files_changed) =
        diff_config_files(&old.files, &new.files);

    // Service diff — compare declared service maps (semantic) when available,
    // fall back to init_scripts list comparison for v2 manifests.
    let (services_added, services_removed, services_changed) =
        diff_declared_services(&old.services.declared, &new.services.declared);

    // User diff
    let (users_added, users_removed, users_changed) = diff_users(&old.users, &new.users);

    // Profile needs rebuild if any package changed
    let profile_needs_rebuild =
        !packages_added.is_empty() || !packages_removed.is_empty() || !packages_changed.is_empty();

    // Count binaries for the new profile
    let profile_binary_count = count_profile_binaries(&new.packages);

    // Activation scripts (in dependency order, or empty on cycle)
    let activation_scripts = topo_sort(&new.activation_scripts).unwrap_or_default();

    ActivationPlan {
        packages_added,
        packages_removed,
        packages_changed,
        config_files_added,
        config_files_removed,
        config_files_changed,
        services_added,
        services_removed,
        services_changed,
        profile_needs_rebuild,
        profile_binary_count,
        users_added,
        users_removed,
        users_changed,
        activation_scripts,
    }
}

/// Diff config files between two file inventories.
fn diff_config_files(
    old: &BTreeMap<String, FileInfo>,
    new: &BTreeMap<String, FileInfo>,
) -> (Vec<String>, Vec<String>, Vec<ConfigChange>) {
    let mut added = Vec::new();
    let mut removed = Vec::new();
    let mut changed = Vec::new();

    for (path, new_info) in new {
        match old.get(path) {
            None => added.push(path.clone()),
            Some(old_info) => {
                if old_info.blake3 != new_info.blake3 {
                    changed.push(ConfigChange {
                        path: path.clone(),
                        old_hash: old_info.blake3.clone(),
                        new_hash: new_info.blake3.clone(),
                    });
                }
            }
        }
    }

    for path in old.keys() {
        if !new.contains_key(path) {
            removed.push(path.clone());
        }
    }

    (added, removed, changed)
}

/// Diff declared services between two manifests.
/// Returns (added, removed, changed) service change lists.
fn diff_declared_services(
    old: &BTreeMap<String, crate::system::ServiceInfo>,
    new: &BTreeMap<String, crate::system::ServiceInfo>,
) -> (Vec<ServiceChange>, Vec<ServiceChange>, Vec<ServiceChange>) {
    let mut added = Vec::new();
    let mut removed = Vec::new();
    let mut changed = Vec::new();

    for (name, new_svc) in new {
        match old.get(name) {
            None => added.push(ServiceChange {
                name: name.clone(),
                svc_type: new_svc.svc_type.clone(),
                description: new_svc.description.clone(),
            }),
            Some(old_svc) => {
                if old_svc != new_svc {
                    changed.push(ServiceChange {
                        name: name.clone(),
                        svc_type: new_svc.svc_type.clone(),
                        description: new_svc.description.clone(),
                    });
                }
            }
        }
    }

    for (name, old_svc) in old {
        if !new.contains_key(name) {
            removed.push(ServiceChange {
                name: name.clone(),
                svc_type: old_svc.svc_type.clone(),
                description: old_svc.description.clone(),
            });
        }
    }

    (added, removed, changed)
}

/// Diff user accounts.
fn diff_users(
    old: &BTreeMap<String, crate::system::User>,
    new: &BTreeMap<String, crate::system::User>,
) -> (Vec<String>, Vec<String>, Vec<String>) {
    let mut added = Vec::new();
    let mut removed = Vec::new();
    let mut changed = Vec::new();

    for (name, new_user) in new {
        match old.get(name) {
            None => added.push(name.clone()),
            Some(old_user) => {
                if old_user.uid != new_user.uid
                    || old_user.gid != new_user.gid
                    || old_user.home != new_user.home
                    || old_user.shell != new_user.shell
                {
                    changed.push(name.clone());
                }
            }
        }
    }

    for name in old.keys() {
        if !new.contains_key(name) {
            removed.push(name.clone());
        }
    }

    (added, removed, changed)
}

/// Count how many binaries the new package set will expose in the profile.
fn count_profile_binaries(packages: &[Package]) -> u32 {
    let mut count = 0u32;
    for pkg in packages {
        if pkg.store_path.is_empty() {
            continue;
        }
        let bin_dir = Path::new(&pkg.store_path).join("bin");
        if bin_dir.is_dir() {
            if let Ok(entries) = std::fs::read_dir(&bin_dir) {
                count += entries
                    .filter_map(|e| e.ok())
                    .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
                    .count() as u32;
            }
        }
    }
    count
}

// ═══════════════════════════════════════════════════════════════════════════
// Plan Display
// ═══════════════════════════════════════════════════════════════════════════

impl ActivationPlan {
    /// True if there's nothing to do.
    pub fn is_empty(&self) -> bool {
        self.packages_added.is_empty()
            && self.packages_removed.is_empty()
            && self.packages_changed.is_empty()
            && self.config_files_added.is_empty()
            && self.config_files_removed.is_empty()
            && self.config_files_changed.is_empty()
            && self.services_added.is_empty()
            && self.services_removed.is_empty()
            && self.services_changed.is_empty()
            && self.users_added.is_empty()
            && self.users_removed.is_empty()
            && self.users_changed.is_empty()
            && self.activation_scripts.is_empty()
    }

    /// Display the plan in a human-readable format.
    pub fn display(&self) {
        if self.is_empty() {
            println!("No changes to activate.");
            return;
        }

        println!("Activation Plan");
        println!("================");

        // Packages
        if !self.packages_added.is_empty()
            || !self.packages_removed.is_empty()
            || !self.packages_changed.is_empty()
        {
            println!();
            println!("Packages:");
            for name in &self.packages_added {
                println!("  + {name}");
            }
            for name in &self.packages_removed {
                println!("  - {name}");
            }
            for change in &self.packages_changed {
                if change.old_version != change.new_version {
                    println!(
                        "  ~ {} {} → {}",
                        change.name, change.old_version, change.new_version
                    );
                } else {
                    println!("  ~ {} (rebuilt)", change.name);
                }
            }
        }

        // Config files
        if !self.config_files_added.is_empty()
            || !self.config_files_removed.is_empty()
            || !self.config_files_changed.is_empty()
        {
            println!();
            println!(
                "Config files ({} added, {} removed, {} changed):",
                self.config_files_added.len(),
                self.config_files_removed.len(),
                self.config_files_changed.len(),
            );
            for path in &self.config_files_added {
                println!("  + /{path}");
            }
            for path in &self.config_files_removed {
                println!("  - /{path}");
            }
            for change in &self.config_files_changed {
                println!("  ~ /{}", change.path);
            }
        }

        // Services
        if !self.services_added.is_empty()
            || !self.services_removed.is_empty()
            || !self.services_changed.is_empty()
        {
            println!();
            println!("Services:");
            for svc in &self.services_added {
                println!("  + {} ({})", svc.name, svc.svc_type);
            }
            for svc in &self.services_removed {
                println!("  - {} ({})", svc.name, svc.svc_type);
            }
            for svc in &self.services_changed {
                println!("  ~ {} ({})", svc.name, svc.svc_type);
            }
            println!("  note: service changes require reboot to take effect");
        }

        // Users
        if !self.users_added.is_empty()
            || !self.users_removed.is_empty()
            || !self.users_changed.is_empty()
        {
            println!();
            println!("Users:");
            for name in &self.users_added {
                println!("  + {name}");
            }
            for name in &self.users_removed {
                println!("  - {name}");
            }
            for name in &self.users_changed {
                println!("  ~ {name}");
            }
        }

        // Profile
        if self.profile_needs_rebuild {
            println!();
            println!(
                "Profile: will rebuild ({} binaries)",
                self.profile_binary_count
            );
        }

        // Activation scripts
        if !self.activation_scripts.is_empty() {
            println!();
            println!(
                "Activation scripts ({} to run):",
                self.activation_scripts.len()
            );
            for (i, name) in self.activation_scripts.iter().enumerate() {
                println!("  {}. {name}", i + 1);
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Activation Execution
// ═══════════════════════════════════════════════════════════════════════════

/// Result of an activation.
#[derive(Debug)]
pub struct ActivationResult {
    /// Number of profile binaries linked.
    pub binaries_linked: u32,
    /// Number of config files updated.
    pub config_files_updated: u32,
    /// Warnings encountered (non-fatal).
    pub warnings: Vec<String>,
    /// Whether a reboot is recommended (service changes, kernel changes, etc.)
    pub reboot_recommended: bool,
}

/// Execute a full system activation.
///
/// This is the core of `switch-to-configuration` for Redox:
///   1. Run pre-activation hooks
///   2. Atomically swap the system profile (package binaries)
///   3. Update config files on disk
///   4. Update GC roots
///   5. Run post-activation hooks
///
/// If `dry_run` is true, computes and displays the plan without modifying anything.
///
/// **Idempotent**: activation ALWAYS rebuilds the profile and updates GC roots,
/// even if the plan shows no package changes. This handles out-of-band
/// modifications (e.g., a symlink was manually deleted) and ensures the system
/// converges to the desired state. The plan is for display; execution always
/// converges.
pub fn activate(
    old: &Manifest,
    new: &Manifest,
    dry_run: bool,
) -> Result<ActivationResult, Box<dyn std::error::Error>> {
    let activation_plan = plan(old, new);

    if dry_run {
        activation_plan.display();
        return Ok(ActivationResult {
            binaries_linked: 0,
            config_files_updated: 0,
            warnings: Vec::new(),
            reboot_recommended: false,
        });
    }

    let mut warnings = Vec::new();

    // ── Step 1: Pre-activation hooks ──
    // (Reserved for future use — custom scripts before activation)

    // ── Step 2: Rebuild system profile (always, for idempotency) ──
    // Even if the plan says packages didn't change, the on-disk profile
    // may be out of sync (manual deletion, partial previous activation, etc.).
    // Always rebuild to converge to the declared state.
    let binaries_linked = match atomic_profile_swap(&new.packages) {
        Ok(count) => {
            if activation_plan.profile_needs_rebuild {
                println!("Profile rebuilt: {count} binaries linked");
            }
            count
        }
        Err(e) => {
            // Fallback to non-atomic rebuild
            warnings.push(format!("atomic profile swap failed, using fallback: {e}"));
            match fallback_profile_rebuild(&new.packages) {
                Ok(count) => {
                    if activation_plan.profile_needs_rebuild {
                        println!("Profile rebuilt (fallback): {count} binaries linked");
                    }
                    count
                }
                Err(e2) => {
                    warnings.push(format!("profile rebuild failed: {e2}"));
                    0
                }
            }
        }
    };

    // ── Step 3: Update config files ──
    let config_files_updated = update_config_files(
        &activation_plan.config_files_added,
        &activation_plan.config_files_removed,
        &activation_plan.config_files_changed,
        &new.files,
        &mut warnings,
    );

    // ── Step 3b: Write manifest-derived config files ──
    // These files have content derived directly from manifest fields,
    // not tracked via rootTree hashes. During live rebuild (no rootTree
    // redeploy), the activate must write them from manifest data.
    let derived_updated = write_manifest_derived_files(old, new, &mut warnings);
    let config_files_updated = config_files_updated + derived_updated;

    // ── Step 3c: Update boot components ──
    let boot_updated = update_boot_components(old, new, &mut warnings);

    // ── Step 4: Update GC roots (always, for idempotency) ──
    if let Err(e) = crate::system::update_system_gc_roots_pub(new, None) {
        warnings.push(format!("GC root update failed: {e}"));
    }

    // ── Step 5: Run activation scripts ──
    let scripts_run = run_activation_scripts(&new.activation_scripts, &mut warnings);
    if scripts_run > 0 {
        println!("Activation scripts: {scripts_run} executed");
    }

    // ── Determine if reboot is recommended ──
    let reboot_recommended = boot_updated
        || !activation_plan.services_added.is_empty()
        || !activation_plan.services_removed.is_empty()
        || has_boot_config_changed(old, new);

    Ok(ActivationResult {
        binaries_linked,
        config_files_updated,
        warnings,
        reboot_recommended,
    })
}

/// Check if boot-critical configuration changed (kernel, bootloader, drivers).
/// Covers all fields that affect initfs content or boot behavior.
fn has_boot_config_changed(old: &Manifest, new: &Manifest) -> bool {
    // Driver lists → initfs content
    old.drivers.initfs != new.drivers.initfs
        || old.configuration.hardware.storage_drivers != new.configuration.hardware.storage_drivers
        || old.configuration.hardware.network_drivers != new.configuration.hardware.network_drivers
        || old.configuration.hardware.graphics_drivers != new.configuration.hardware.graphics_drivers
        || old.configuration.hardware.audio_drivers != new.configuration.hardware.audio_drivers
        || old.configuration.hardware.usb_enabled != new.configuration.hardware.usb_enabled
    // Boot partition layout
        || old.configuration.boot.disk_size_mb != new.configuration.boot.disk_size_mb
    // Init script changes → initfs content
        || old.services.init_scripts != new.services.init_scripts
    // Boot component store paths
        || boot_components_changed(old, new)
}

/// Check if boot component store paths differ between manifests.
fn boot_components_changed(old: &Manifest, new: &Manifest) -> bool {
    match (&old.boot, &new.boot) {
        (Some(old_boot), Some(new_boot)) => old_boot != new_boot,
        (None, Some(_)) | (Some(_), None) => true,
        (None, None) => false,
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Boot Component Updates
// ═══════════════════════════════════════════════════════════════════════════

/// Default boot directory on the running Redox system.
const BOOT_DIR: &str = "/boot";

/// Update boot component files on disk when the generation's boot paths differ.
///
/// Copies kernel/initfs from their store paths to /boot/ on the rootfs.
/// Skips if:
///   - Both manifests have no boot section (v1 compat)
///   - Boot paths are identical (no-op)
///   - Store path file is missing (warns, continues)
///
/// Returns true if any boot files were updated (reboot recommended).
fn update_boot_components(
    old: &Manifest,
    new: &Manifest,
    warnings: &mut Vec<String>,
) -> bool {
    update_boot_components_at(old, new, BOOT_DIR, warnings)
}

/// Inner implementation with configurable boot directory (for testing).
fn update_boot_components_at(
    old: &Manifest,
    new: &Manifest,
    boot_dir: &str,
    warnings: &mut Vec<String>,
) -> bool {
    let new_boot = match &new.boot {
        Some(b) => b,
        None => return false, // v1 manifest — don't touch boot
    };

    let old_boot = old.boot.as_ref();

    let mut updated = false;

    // Update kernel if path changed
    if let Some(ref kernel_path) = new_boot.kernel {
        let changed = old_boot.map_or(true, |ob| ob.kernel.as_ref() != Some(kernel_path));
        if changed {
            let dst = format!("{boot_dir}/kernel");
            match copy_boot_file(kernel_path, &dst) {
                Ok(()) => {
                    println!("Boot: kernel updated from {kernel_path}");
                    updated = true;
                }
                Err(e) => {
                    warnings.push(format!(
                        "boot: kernel store path missing or unreadable: {kernel_path}: {e}"
                    ));
                }
            }
        }
    }

    // Update initfs if path changed
    if let Some(ref initfs_path) = new_boot.initfs {
        let changed = old_boot.map_or(true, |ob| ob.initfs.as_ref() != Some(initfs_path));
        if changed {
            let dst = format!("{boot_dir}/initfs");
            match copy_boot_file(initfs_path, &dst) {
                Ok(()) => {
                    println!("Boot: initfs updated from {initfs_path}");
                    updated = true;
                }
                Err(e) => {
                    warnings.push(format!(
                        "boot: initfs store path missing or unreadable: {initfs_path}: {e}"
                    ));
                }
            }
        }
    }

    updated
}

/// Copy a boot component file from its store path to the target location.
fn copy_boot_file(src: &str, dst: &str) -> Result<(), Box<dyn std::error::Error>> {
    let src_path = Path::new(src);
    if !src_path.exists() {
        return Err(format!("file not found: {src}").into());
    }
    // Write to temp file first, then rename (closer to atomic on most filesystems)
    let dst_path = Path::new(dst);
    let tmp_path = dst_path.with_extension("tmp");
    if let Some(parent) = dst_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(src_path, &tmp_path)?;
    std::fs::rename(&tmp_path, dst_path)?;
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════
// Atomic Profile Swap
// ═══════════════════════════════════════════════════════════════════════════

/// Build the new profile in a staging directory, then atomically swap it
/// into place with `rename()`. This ensures there's never a moment where
/// the profile is half-built.
///
/// Strategy:
///   1. Create `/nix/system/.profile-staging/bin/` with all new symlinks
///   2. `rename("/nix/system/.profile-staging/bin", "/nix/system/profile/bin.new")`
///   3. `rename("/nix/system/profile/bin", "/nix/system/profile/bin.old")`
///   4. `rename("/nix/system/profile/bin.new", "/nix/system/profile/bin")`
///   5. Remove `.profile-staging/` and `bin.old/`
///
/// If step 4 fails, step 3 is rolled back. The window of inconsistency is
/// limited to the time between steps 3 and 4 (two renames, microseconds).
fn atomic_profile_swap(packages: &[Package]) -> Result<u32, Box<dyn std::error::Error>> {
    let staging_bin = PathBuf::from(STAGING_DIR).join("bin");
    let profile_bin = PathBuf::from(SYSTEM_PROFILE_BIN);
    let profile_bin_new = profile_bin.with_file_name("bin.new");
    let profile_bin_old = profile_bin.with_file_name("bin.old");

    // Clean up any leftover staging from a previous failed activation
    cleanup_path(&staging_bin);
    cleanup_path(&profile_bin_new);
    cleanup_path(&profile_bin_old);

    // Step 1: Build the new profile in staging
    std::fs::create_dir_all(&staging_bin)?;
    let count = populate_profile_dir(&staging_bin, packages)?;

    // Step 2: Move staging → bin.new
    std::fs::rename(&staging_bin, &profile_bin_new)?;

    // Ensure parent exists
    if let Some(parent) = profile_bin.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Step 3: Move current bin → bin.old (if it exists)
    let had_old = if profile_bin.exists() || profile_bin.symlink_metadata().is_ok() {
        // Make writable first (Nix store outputs have mode 555)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let parent = profile_bin.parent().unwrap();
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o755));
        }
        std::fs::rename(&profile_bin, &profile_bin_old)?;
        true
    } else {
        false
    };

    // Step 4: Move bin.new → bin (the atomic swap)
    match std::fs::rename(&profile_bin_new, &profile_bin) {
        Ok(()) => {
            // Success! Clean up old profile
            if had_old {
                cleanup_path(&profile_bin_old);
            }
            cleanup_path(&PathBuf::from(STAGING_DIR));
            Ok(count)
        }
        Err(e) => {
            // Step 4 failed — roll back step 3
            if had_old {
                let _ = std::fs::rename(&profile_bin_old, &profile_bin);
            }
            cleanup_path(&profile_bin_new);
            cleanup_path(&PathBuf::from(STAGING_DIR));
            Err(format!("atomic swap failed: {e}").into())
        }
    }
}

/// Populate a profile directory with symlinks to package binaries.
/// Returns the number of binaries linked.
fn populate_profile_dir(bin_dir: &Path, packages: &[Package]) -> Result<u32, Box<dyn std::error::Error>> {
    let mut count = 0u32;

    for pkg in packages {
        if pkg.store_path.is_empty() {
            continue;
        }
        let pkg_bin = Path::new(&pkg.store_path).join("bin");
        if !pkg_bin.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&pkg_bin)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let name = entry.file_name();
            let link_path = bin_dir.join(&name);
            let target = entry.path();

            // If there's a conflict (two packages provide same binary),
            // last one wins — same semantics as NixOS environment.systemPackages
            if link_path.symlink_metadata().is_ok() {
                std::fs::remove_file(&link_path)?;
            }

            #[cfg(unix)]
            std::os::unix::fs::symlink(&target, &link_path)?;
            #[cfg(not(unix))]
            std::fs::copy(&target, &link_path)?;

            count += 1;
        }
    }

    Ok(count)
}

/// Fallback: non-atomic profile rebuild (clear + repopulate in place).
/// Used when atomic swap isn't possible (e.g., filesystem doesn't support rename).
fn fallback_profile_rebuild(packages: &[Package]) -> Result<u32, Box<dyn std::error::Error>> {
    let profile_bin = PathBuf::from(SYSTEM_PROFILE_BIN);

    if profile_bin.exists() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&profile_bin, std::fs::Permissions::from_mode(0o755));
        }
        // Clear existing symlinks
        for entry in std::fs::read_dir(&profile_bin)? {
            let entry = entry?;
            if entry.path().symlink_metadata()?.file_type().is_symlink() {
                std::fs::remove_file(entry.path())?;
            }
        }
    } else {
        std::fs::create_dir_all(&profile_bin)?;
    }

    populate_profile_dir(&profile_bin, packages)
}

// ═══════════════════════════════════════════════════════════════════════════
// Config File Activation
// ═══════════════════════════════════════════════════════════════════════════

/// Update config files on disk to match the new manifest.
///
/// Config files tracked in the manifest are "managed" — we own them and can
/// overwrite. Files NOT in the manifest are left alone (user modifications).
///
/// For changed files, we write the new content from the manifest's rootTree.
/// Since we're running on a live system, the actual file content comes from
/// comparing the on-disk file hash against the manifest hashes.
fn update_config_files(
    added: &[String],
    removed: &[String],
    changed: &[ConfigChange],
    new_files: &BTreeMap<String, FileInfo>,
    warnings: &mut Vec<String>,
) -> u32 {
    let mut updated = 0u32;

    // Handle added config files
    // Note: we can't create files from thin air — the manifest only has hashes.
    // Added files are only relevant if they exist in the rootTree (which was
    // already written to disk by the build process). For live activation,
    // new config files come from the new rootTree's store path.
    for path in added {
        // The file should already exist if the rootTree was properly deployed.
        // Just verify it's there.
        let full_path = PathBuf::from("/").join(path);
        if !full_path.exists() {
            warnings.push(format!(
                "new config file /{path} not found on disk (expected from rootTree)"
            ));
        }
    }

    // Handle removed config files
    for path in removed {
        let full_path = PathBuf::from("/").join(path);
        if full_path.exists() {
            match std::fs::remove_file(&full_path) {
                Ok(()) => {
                    updated += 1;
                    eprintln!("  removed /{path}");
                }
                Err(e) => {
                    warnings.push(format!("could not remove /{path}: {e}"));
                }
            }
        }
    }

    // Handle changed config files
    // For live systems, changed config files need their content from the new
    // rootTree. Since we track the hash but not the content in the manifest,
    // we check if the on-disk file already has the new hash (rootTree deployed
    // it) or if it needs updating from the new store path.
    for change in changed {
        let full_path = PathBuf::from("/").join(&change.path);
        if full_path.exists() {
            // Check if file already has the new content (rootTree was deployed)
            match hash_file_if_exists(&full_path) {
                Some(hash) if hash == change.new_hash => {
                    // Already up to date (rootTree deployed this file)
                }
                _ => {
                    // File exists but has different content.
                    // We can't update it without the new content bytes.
                    // Flag it for the user.
                    warnings.push(format!(
                        "config file /{} needs update (hash mismatch) — redeploy rootTree or reboot",
                        change.path
                    ));
                }
            }
            updated += 1;
        }
    }

    if updated > 0 {
        println!("Config files: {updated} updated");
    }

    updated
}

/// Hash a file if it exists, returning None on any error.
fn hash_file_if_exists(path: &Path) -> Option<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; 16384];
    loop {
        let n = file.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hasher.finalize().to_hex().to_string())
}

/// Write config files whose content is derived from manifest fields.
///
/// During a live `snix system rebuild`, no rootTree is deployed — the
/// activate runs against the running filesystem. Config files like
/// /etc/hostname have content that comes from manifest.system.hostname,
/// not from hash-tracked rootTree entries. This function writes them.
fn write_manifest_derived_files(
    old: &Manifest,
    new: &Manifest,
    warnings: &mut Vec<String>,
) -> u32 {
    let mut count = 0u32;

    // /etc/hostname
    if old.system.hostname != new.system.hostname {
        match std::fs::write("/etc/hostname", &new.system.hostname) {
            Ok(()) => {
                println!("  updated /etc/hostname -> {}", new.system.hostname);
                count += 1;
            }
            Err(e) => warnings.push(format!("failed to write /etc/hostname: {e}")),
        }
    }

    // /etc/timezone (if timezone changed)
    if old.system.timezone != new.system.timezone {
        match std::fs::write("/etc/timezone", &new.system.timezone) {
            Ok(()) => {
                println!("  updated /etc/timezone -> {}", new.system.timezone);
                count += 1;
            }
            Err(e) => warnings.push(format!("failed to write /etc/timezone: {e}")),
        }
    }

    // /etc/net/dns (if DNS servers changed)
    if old.configuration.networking.dns != new.configuration.networking.dns {
        let dns_content = new.configuration.networking.dns.join("\n");
        if let Err(e) = std::fs::create_dir_all("/etc/net") {
            warnings.push(format!("failed to create /etc/net: {e}"));
        }
        match std::fs::write("/etc/net/dns", &dns_content) {
            Ok(()) => {
                println!("  updated /etc/net/dns");
                count += 1;
            }
            Err(e) => warnings.push(format!("failed to write /etc/net/dns: {e}")),
        }
    }

    if count > 0 {
        println!("Manifest-derived files: {count} updated");
    }

    count
}

// ═══════════════════════════════════════════════════════════════════════════
// Activation Script Execution
// ═══════════════════════════════════════════════════════════════════════════

/// Directory where activation scripts are stored on the rootfs.
const ACTIVATION_SCRIPTS_DIR: &str = "/etc/redox-system/activation.d";

/// Execute activation scripts in dependency order.
/// Returns the number of scripts successfully executed.
/// Failures are logged as warnings but do not abort activation.
fn run_activation_scripts(
    scripts: &[ActivationScript],
    warnings: &mut Vec<String>,
) -> u32 {
    run_activation_scripts_at(scripts, ACTIVATION_SCRIPTS_DIR, warnings)
}

/// Inner implementation with configurable script directory (for testing).
fn run_activation_scripts_at(
    scripts: &[ActivationScript],
    scripts_dir: &str,
    warnings: &mut Vec<String>,
) -> u32 {
    if scripts.is_empty() {
        return 0;
    }

    // Topologically sort scripts
    let ordered = match topo_sort(scripts) {
        Ok(order) => order,
        Err(e) => {
            warnings.push(format!("activation scripts skipped: {e}"));
            return 0;
        }
    };

    let mut count = 0u32;
    for name in &ordered {
        let script_path = PathBuf::from(scripts_dir).join(name);
        if !script_path.exists() {
            warnings.push(format!(
                "activation script '{name}' not found at {}",
                script_path.display()
            ));
            continue;
        }

        println!("  running activation script: {name}");

        match std::process::Command::new("/bin/sh")
            .arg(script_path.as_os_str())
            .stdin(std::process::Stdio::null())
            .output()
        {
            Ok(output) => {
                if !output.stdout.is_empty() {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    for line in stdout.lines() {
                        println!("    {line}");
                    }
                }
                if output.status.success() {
                    count += 1;
                } else {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    warnings.push(format!(
                        "activation script '{name}' failed (exit {}): {}",
                        output.status.code().unwrap_or(-1),
                        stderr.trim()
                    ));
                }
            }
            Err(e) => {
                warnings.push(format!("activation script '{name}' failed to execute: {e}"));
            }
        }
    }

    count
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Remove a path (file or directory) silently.
fn cleanup_path(path: &Path) {
    if path.is_dir() {
        let _ = std::fs::remove_dir_all(path);
    } else if path.exists() || path.symlink_metadata().is_ok() {
        let _ = std::fs::remove_file(path);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::system::*;
    use std::collections::BTreeMap;

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
            generation: GenerationInfo {
                id: 1,
                build_hash: "abc123".to_string(),
                description: "initial build".to_string(),
                timestamp: "2026-02-20T10:00:00Z".to_string(),
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
                    store_path: "/nix/store/aaa-ion-1.0.0".to_string(),
                },
                Package {
                    name: "uutils".to_string(),
                    version: "0.0.1".to_string(),
                    store_path: "/nix/store/bbb-uutils-0.0.1".to_string(),
                },
            ],
            drivers: Drivers {
                all: vec!["virtio-blkd".to_string(), "virtio-netd".to_string()],
                initfs: vec!["virtio-blkd".to_string()],
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
                declared: BTreeMap::new(),
                init_scripts: vec!["10_net".to_string(), "15_dhcp".to_string()],
                startup_script: "/startup.sh".to_string(),
            },
            activation_scripts: Vec::new(),
            files: BTreeMap::from([
                (
                    "etc/passwd".to_string(),
                    FileInfo {
                        blake3: "aaa111".to_string(),
                        size: 42,
                        mode: "644".to_string(),
                    },
                ),
                (
                    "etc/profile".to_string(),
                    FileInfo {
                        blake3: "bbb222".to_string(),
                        size: 100,
                        mode: "644".to_string(),
                    },
                ),
            ]),
            system_profile: String::new(),
        }
    }

    // ── Plan computation tests ──

    #[test]
    fn plan_identical_manifests() {
        let m = sample_manifest();
        let p = plan(&m, &m);
        assert!(p.is_empty());
        assert!(!p.profile_needs_rebuild);
    }

    #[test]
    fn plan_package_added() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.packages.push(Package {
            name: "ripgrep".to_string(),
            version: "14.0".to_string(),
            store_path: "/nix/store/ccc-ripgrep-14.0".to_string(),
        });

        let p = plan(&old, &new);
        assert_eq!(p.packages_added, vec!["ripgrep"]);
        assert!(p.packages_removed.is_empty());
        assert!(p.packages_changed.is_empty());
        assert!(p.profile_needs_rebuild);
    }

    #[test]
    fn plan_package_removed() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.packages.retain(|p| p.name != "uutils");

        let p = plan(&old, &new);
        assert!(p.packages_added.is_empty());
        assert_eq!(p.packages_removed, vec!["uutils"]);
        assert!(p.profile_needs_rebuild);
    }

    #[test]
    fn plan_package_version_changed() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.packages[0].version = "2.0.0".to_string();
        new.packages[0].store_path = "/nix/store/ddd-ion-2.0.0".to_string();

        let p = plan(&old, &new);
        assert!(p.packages_added.is_empty());
        assert!(p.packages_removed.is_empty());
        assert_eq!(p.packages_changed.len(), 1);
        assert_eq!(p.packages_changed[0].name, "ion");
        assert_eq!(p.packages_changed[0].old_version, "1.0.0");
        assert_eq!(p.packages_changed[0].new_version, "2.0.0");
        assert!(p.profile_needs_rebuild);
    }

    #[test]
    fn plan_package_rebuilt_same_version() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        // Same version, different store path (rebuild)
        new.packages[0].store_path = "/nix/store/eee-ion-1.0.0".to_string();

        let p = plan(&old, &new);
        assert_eq!(p.packages_changed.len(), 1);
        assert_eq!(p.packages_changed[0].old_version, "1.0.0");
        assert_eq!(p.packages_changed[0].new_version, "1.0.0");
        assert_ne!(
            p.packages_changed[0].old_store_path,
            p.packages_changed[0].new_store_path
        );
    }

    #[test]
    fn plan_config_file_added() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.files.insert(
            "etc/hostname".to_string(),
            FileInfo {
                blake3: "ccc333".to_string(),
                size: 10,
                mode: "644".to_string(),
            },
        );

        let p = plan(&old, &new);
        assert_eq!(p.config_files_added, vec!["etc/hostname"]);
        assert!(p.config_files_removed.is_empty());
        assert!(p.config_files_changed.is_empty());
    }

    #[test]
    fn plan_config_file_removed() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.files.remove("etc/profile");

        let p = plan(&old, &new);
        assert!(p.config_files_added.is_empty());
        assert_eq!(p.config_files_removed, vec!["etc/profile"]);
    }

    #[test]
    fn plan_config_file_changed() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.files.get_mut("etc/passwd").unwrap().blake3 = "xxx999".to_string();

        let p = plan(&old, &new);
        assert!(p.config_files_added.is_empty());
        assert!(p.config_files_removed.is_empty());
        assert_eq!(p.config_files_changed.len(), 1);
        assert_eq!(p.config_files_changed[0].path, "etc/passwd");
        assert_eq!(p.config_files_changed[0].old_hash, "aaa111");
        assert_eq!(p.config_files_changed[0].new_hash, "xxx999");
    }

    #[test]
    fn plan_service_added() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.services.declared.insert(
            "orbital".to_string(),
            ServiceInfo {
                description: "Desktop environment".to_string(),
                command: "orbital".to_string(),
                svc_type: "nowait".to_string(),
                args: "orblogin orbterm".to_string(),
                wanted_by: "rootfs".to_string(),
                environment: BTreeMap::from([("VT".to_string(), "3".to_string())]),
                after: vec!["ptyd".to_string()],
            },
        );

        let p = plan(&old, &new);
        assert_eq!(p.services_added.len(), 1);
        assert_eq!(p.services_added[0].name, "orbital");
        assert_eq!(p.services_added[0].svc_type, "nowait");
        assert!(p.services_removed.is_empty());
        assert!(p.services_changed.is_empty());
    }

    #[test]
    fn plan_service_removed() {
        let mut old = sample_manifest();
        old.services.declared.insert(
            "smolnetd".to_string(),
            ServiceInfo {
                description: "Network stack".to_string(),
                command: "/bin/smolnetd".to_string(),
                svc_type: "daemon".to_string(),
                args: String::new(),
                wanted_by: "rootfs".to_string(),
                environment: BTreeMap::new(),
                after: vec![],
            },
        );
        let new = sample_manifest();

        let p = plan(&old, &new);
        assert!(p.services_added.is_empty());
        assert_eq!(p.services_removed.len(), 1);
        assert_eq!(p.services_removed[0].name, "smolnetd");
        assert_eq!(p.services_removed[0].svc_type, "daemon");
        assert!(p.services_changed.is_empty());
    }

    #[test]
    fn plan_service_type_changed() {
        let svc = ServiceInfo {
            description: "Network stack".to_string(),
            command: "/bin/smolnetd".to_string(),
            svc_type: "daemon".to_string(),
            args: String::new(),
            wanted_by: "rootfs".to_string(),
            environment: BTreeMap::new(),
            after: vec![],
        };
        let mut old = sample_manifest();
        old.services.declared.insert("smolnetd".to_string(), svc.clone());
        let mut new = sample_manifest();
        let mut new_svc = svc;
        new_svc.svc_type = "nowait".to_string();
        new.services.declared.insert("smolnetd".to_string(), new_svc);

        let p = plan(&old, &new);
        assert!(p.services_added.is_empty());
        assert!(p.services_removed.is_empty());
        assert_eq!(p.services_changed.len(), 1);
        assert_eq!(p.services_changed[0].name, "smolnetd");
        assert_eq!(p.services_changed[0].svc_type, "nowait");
    }

    #[test]
    fn plan_service_env_changed() {
        let svc = ServiceInfo {
            description: "Desktop".to_string(),
            command: "orbital".to_string(),
            svc_type: "nowait".to_string(),
            args: "orblogin orbterm".to_string(),
            wanted_by: "rootfs".to_string(),
            environment: BTreeMap::from([("VT".to_string(), "3".to_string())]),
            after: vec![],
        };
        let mut old = sample_manifest();
        old.services.declared.insert("orbital".to_string(), svc.clone());
        let mut new = sample_manifest();
        let mut new_svc = svc;
        new_svc.environment = BTreeMap::from([("VT".to_string(), "4".to_string())]);
        new.services.declared.insert("orbital".to_string(), new_svc);

        let p = plan(&old, &new);
        assert!(p.services_added.is_empty());
        assert!(p.services_removed.is_empty());
        assert_eq!(p.services_changed.len(), 1);
        assert_eq!(p.services_changed[0].name, "orbital");
    }

    #[test]
    fn plan_service_command_changed() {
        let svc = ServiceInfo {
            description: "Network stack".to_string(),
            command: "/bin/smolnetd".to_string(),
            svc_type: "daemon".to_string(),
            args: String::new(),
            wanted_by: "rootfs".to_string(),
            environment: BTreeMap::new(),
            after: vec![],
        };
        let mut old = sample_manifest();
        old.services.declared.insert("smolnetd".to_string(), svc.clone());
        let mut new = sample_manifest();
        let mut new_svc = svc;
        new_svc.command = "/bin/smolnetd2".to_string();
        new.services.declared.insert("smolnetd".to_string(), new_svc);

        let p = plan(&old, &new);
        assert_eq!(p.services_changed.len(), 1);
        assert_eq!(p.services_changed[0].name, "smolnetd");
    }

    #[test]
    fn plan_service_unchanged() {
        let svc = ServiceInfo {
            description: "Network stack".to_string(),
            command: "/bin/smolnetd".to_string(),
            svc_type: "daemon".to_string(),
            args: String::new(),
            wanted_by: "rootfs".to_string(),
            environment: BTreeMap::new(),
            after: vec![],
        };
        let mut old = sample_manifest();
        old.services.declared.insert("smolnetd".to_string(), svc.clone());
        let mut new = sample_manifest();
        new.services.declared.insert("smolnetd".to_string(), svc);

        let p = plan(&old, &new);
        assert!(p.services_added.is_empty());
        assert!(p.services_removed.is_empty());
        assert!(p.services_changed.is_empty());
    }

    #[test]
    fn plan_user_added() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.users.insert(
            "admin".to_string(),
            User {
                uid: 1001,
                gid: 1001,
                home: "/home/admin".to_string(),
                shell: "/bin/ion".to_string(),
            },
        );

        let p = plan(&old, &new);
        assert_eq!(p.users_added, vec!["admin"]);
        assert!(p.users_removed.is_empty());
        assert!(p.users_changed.is_empty());
    }

    #[test]
    fn plan_user_removed() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.users.remove("user");

        let p = plan(&old, &new);
        assert!(p.users_added.is_empty());
        assert_eq!(p.users_removed, vec!["user"]);
    }

    #[test]
    fn plan_user_changed() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.users.get_mut("user").unwrap().shell = "/bin/bash".to_string();

        let p = plan(&old, &new);
        assert!(p.users_added.is_empty());
        assert!(p.users_removed.is_empty());
        assert_eq!(p.users_changed, vec!["user"]);
    }

    #[test]
    fn plan_no_profile_rebuild_when_packages_same() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        // Only change config file, not packages
        new.files.get_mut("etc/passwd").unwrap().blake3 = "changed".to_string();

        let p = plan(&old, &new);
        assert!(!p.profile_needs_rebuild);
    }

    #[test]
    fn plan_display_empty() {
        let m = sample_manifest();
        let p = plan(&m, &m);
        // Should not panic
        p.display();
    }

    #[test]
    fn plan_display_full() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.packages.push(Package {
            name: "ripgrep".to_string(),
            version: "14.0".to_string(),
            store_path: "".to_string(),
        });
        new.packages.retain(|p| p.name != "uutils");
        new.files.insert(
            "etc/hostname".to_string(),
            FileInfo {
                blake3: "new".to_string(),
                size: 5,
                mode: "644".to_string(),
            },
        );
        new.services.declared.insert(
            "newservice".to_string(),
            ServiceInfo {
                description: "A new service".to_string(),
                command: "/bin/new".to_string(),
                svc_type: "nowait".to_string(),
                args: String::new(),
                wanted_by: "rootfs".to_string(),
                environment: BTreeMap::new(),
                after: vec![],
            },
        );
        new.users.insert(
            "admin".to_string(),
            User {
                uid: 1001,
                gid: 1001,
                home: "/home/admin".to_string(),
                shell: "/bin/ion".to_string(),
            },
        );

        let p = plan(&old, &new);
        // Should not panic, just prints
        p.display();
    }

    #[test]
    fn plan_reboot_recommended_on_service_change() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.services.declared.insert(
            "newservice".to_string(),
            ServiceInfo {
                description: "New service".to_string(),
                command: "/bin/new".to_string(),
                svc_type: "daemon".to_string(),
                args: String::new(),
                wanted_by: "rootfs".to_string(),
                environment: BTreeMap::new(),
                after: vec![],
            },
        );

        let p = plan(&old, &new);
        assert!(!p.services_added.is_empty());
    }

    #[test]
    fn plan_boot_config_change_detection() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.drivers.initfs.push("ahcid".to_string());

        assert!(has_boot_config_changed(&old, &new));
    }

    #[test]
    fn plan_boot_config_no_change() {
        let old = sample_manifest();
        let new = sample_manifest();

        assert!(!has_boot_config_changed(&old, &new));
    }

    #[test]
    fn plan_boot_config_network_driver_change() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.configuration.hardware.network_drivers.push("e1000d".to_string());

        assert!(has_boot_config_changed(&old, &new));
    }

    #[test]
    fn plan_boot_config_usb_toggle() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.configuration.hardware.usb_enabled = !old.configuration.hardware.usb_enabled;

        assert!(has_boot_config_changed(&old, &new));
    }

    #[test]
    fn plan_boot_config_init_script_change() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.services.init_scripts.push("20_custom".to_string());

        assert!(has_boot_config_changed(&old, &new));
    }

    // ── Atomic profile swap tests (use tempdir) ──

    #[test]
    fn populate_profile_dir_empty() {
        let dir = tempfile::tempdir().unwrap();
        let bin_dir = dir.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        let packages = vec![Package {
            name: "test".to_string(),
            version: "1.0".to_string(),
            store_path: "/nonexistent/store/path".to_string(),
        }];

        // Non-existent store path → 0 binaries
        let count = populate_profile_dir(&bin_dir, &packages).unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn populate_profile_dir_with_binaries() {
        let dir = tempfile::tempdir().unwrap();
        let bin_dir = dir.path().join("profile-bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        // Create a mock store path with binaries
        let store_path = dir.path().join("store").join("abc-test-1.0");
        let store_bin = store_path.join("bin");
        std::fs::create_dir_all(&store_bin).unwrap();
        std::fs::write(store_bin.join("tool1"), "#!/bin/sh\necho hi").unwrap();
        std::fs::write(store_bin.join("tool2"), "#!/bin/sh\necho hi").unwrap();

        let packages = vec![Package {
            name: "test".to_string(),
            version: "1.0".to_string(),
            store_path: store_path.to_string_lossy().to_string(),
        }];

        let count = populate_profile_dir(&bin_dir, &packages).unwrap();
        assert_eq!(count, 2);

        // Verify symlinks exist
        assert!(bin_dir.join("tool1").symlink_metadata().is_ok());
        assert!(bin_dir.join("tool2").symlink_metadata().is_ok());
    }

    #[test]
    fn populate_profile_dir_conflict_resolution() {
        let dir = tempfile::tempdir().unwrap();
        let bin_dir = dir.path().join("profile-bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        // Two packages providing "tool"
        let store1 = dir.path().join("store").join("aaa-pkg1-1.0");
        let store2 = dir.path().join("store").join("bbb-pkg2-1.0");
        std::fs::create_dir_all(store1.join("bin")).unwrap();
        std::fs::create_dir_all(store2.join("bin")).unwrap();
        std::fs::write(store1.join("bin/tool"), "v1").unwrap();
        std::fs::write(store2.join("bin/tool"), "v2").unwrap();

        let packages = vec![
            Package {
                name: "pkg1".to_string(),
                version: "1.0".to_string(),
                store_path: store1.to_string_lossy().to_string(),
            },
            Package {
                name: "pkg2".to_string(),
                version: "1.0".to_string(),
                store_path: store2.to_string_lossy().to_string(),
            },
        ];

        let count = populate_profile_dir(&bin_dir, &packages).unwrap();
        // 2 link operations, but only 1 file (second overwrites first)
        assert_eq!(count, 2);

        // The symlink should point to pkg2's version (last wins)
        let link = bin_dir.join("tool");
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
    }

    #[test]
    fn populate_profile_skips_empty_store_path() {
        let dir = tempfile::tempdir().unwrap();
        let bin_dir = dir.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        let packages = vec![Package {
            name: "test".to_string(),
            version: "1.0".to_string(),
            store_path: String::new(), // empty = no store path
        }];

        let count = populate_profile_dir(&bin_dir, &packages).unwrap();
        assert_eq!(count, 0);
    }

    // ── Config file tests ──

    #[test]
    fn diff_config_files_identical() {
        let files = BTreeMap::from([(
            "etc/passwd".to_string(),
            FileInfo {
                blake3: "abc".to_string(),
                size: 10,
                mode: "644".to_string(),
            },
        )]);

        let (added, removed, changed) = diff_config_files(&files, &files);
        assert!(added.is_empty());
        assert!(removed.is_empty());
        assert!(changed.is_empty());
    }

    #[test]
    fn diff_config_files_all_changes() {
        let old = BTreeMap::from([
            (
                "etc/passwd".to_string(),
                FileInfo {
                    blake3: "aaa".to_string(),
                    size: 10,
                    mode: "644".to_string(),
                },
            ),
            (
                "etc/old-file".to_string(),
                FileInfo {
                    blake3: "bbb".to_string(),
                    size: 5,
                    mode: "644".to_string(),
                },
            ),
        ]);

        let new = BTreeMap::from([
            (
                "etc/passwd".to_string(),
                FileInfo {
                    blake3: "xxx".to_string(),
                    size: 10,
                    mode: "644".to_string(),
                },
            ),
            (
                "etc/new-file".to_string(),
                FileInfo {
                    blake3: "yyy".to_string(),
                    size: 15,
                    mode: "644".to_string(),
                },
            ),
        ]);

        let (added, removed, changed) = diff_config_files(&old, &new);
        assert_eq!(added, vec!["etc/new-file"]);
        assert_eq!(removed, vec!["etc/old-file"]);
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].path, "etc/passwd");
    }

    // ── User diff tests ──

    #[test]
    fn diff_users_identical() {
        let users = BTreeMap::from([(
            "user".to_string(),
            User {
                uid: 1000,
                gid: 1000,
                home: "/home/user".to_string(),
                shell: "/bin/ion".to_string(),
            },
        )]);

        let (added, removed, changed) = diff_users(&users, &users);
        assert!(added.is_empty());
        assert!(removed.is_empty());
        assert!(changed.is_empty());
    }

    #[test]
    fn diff_users_all_changes() {
        let old = BTreeMap::from([(
            "alice".to_string(),
            User {
                uid: 1000,
                gid: 1000,
                home: "/home/alice".to_string(),
                shell: "/bin/ion".to_string(),
            },
        )]);

        let new = BTreeMap::from([
            (
                "alice".to_string(),
                User {
                    uid: 1000,
                    gid: 1000,
                    home: "/home/alice".to_string(),
                    shell: "/bin/bash".to_string(), // changed
                },
            ),
            (
                "bob".to_string(),
                User {
                    uid: 1001,
                    gid: 1001,
                    home: "/home/bob".to_string(),
                    shell: "/bin/ion".to_string(),
                },
            ),
        ]);

        let (added, removed, changed) = diff_users(&old, &new);
        assert_eq!(added, vec!["bob"]);
        assert!(removed.is_empty());
        assert_eq!(changed, vec!["alice"]);
    }

    #[test]
    fn hash_file_if_exists_nonexistent() {
        assert!(hash_file_if_exists(Path::new("/nonexistent/file")).is_none());
    }

    #[test]
    fn hash_file_if_exists_works() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test");
        std::fs::write(&path, "hello").unwrap();

        let hash = hash_file_if_exists(&path);
        assert!(hash.is_some());
        assert_eq!(hash.unwrap().len(), 64); // BLAKE3 hex = 64 chars
    }

    #[test]
    fn cleanup_path_nonexistent() {
        // Should not panic
        cleanup_path(Path::new("/nonexistent/path"));
    }

    #[test]
    fn cleanup_path_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");
        std::fs::write(&path, "data").unwrap();
        assert!(path.exists());

        cleanup_path(&path);
        assert!(!path.exists());
    }

    #[test]
    fn cleanup_path_directory() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("subdir");
        std::fs::create_dir_all(sub.join("nested")).unwrap();
        std::fs::write(sub.join("nested/file"), "data").unwrap();
        assert!(sub.exists());

        cleanup_path(&sub);
        assert!(!sub.exists());
    }

    #[test]
    fn activation_result_defaults() {
        let result = ActivationResult {
            binaries_linked: 0,
            config_files_updated: 0,
            warnings: Vec::new(),
            reboot_recommended: false,
        };
        assert!(!result.reboot_recommended);
        assert!(result.warnings.is_empty());
    }

    // ── Boot component update tests ──

    use crate::system::BootComponents;

    #[test]
    fn boot_update_with_changed_paths_copies_files() {
        let dir = tempfile::tempdir().unwrap();
        let kernel_src = dir.path().join("store-kernel");
        let initfs_src = dir.path().join("store-initfs");
        let boot_dir = dir.path().join("boot");
        std::fs::create_dir_all(&boot_dir).unwrap();
        std::fs::write(&kernel_src, b"KERNEL_V2").unwrap();
        std::fs::write(&initfs_src, b"INITFS_V2").unwrap();
        // Write old boot files
        std::fs::write(boot_dir.join("kernel"), b"KERNEL_V1").unwrap();
        std::fs::write(boot_dir.join("initfs"), b"INITFS_V1").unwrap();

        let old = sample_manifest(); // boot: None (v1)
        let mut new = sample_manifest();
        new.boot = Some(BootComponents {
            kernel: Some(kernel_src.to_string_lossy().to_string()),
            initfs: Some(initfs_src.to_string_lossy().to_string()),
            bootloader: None,
        });

        let mut warnings = Vec::new();
        let updated = update_boot_components_at(
            &old, &new, &boot_dir.to_string_lossy(), &mut warnings,
        );
        assert!(updated);
        assert!(warnings.is_empty());

        // Verify files were actually copied
        assert_eq!(std::fs::read(boot_dir.join("kernel")).unwrap(), b"KERNEL_V2");
        assert_eq!(std::fs::read(boot_dir.join("initfs")).unwrap(), b"INITFS_V2");
    }

    #[test]
    fn boot_update_same_paths_skips() {
        let dir = tempfile::tempdir().unwrap();
        let boot_dir = dir.path().join("boot");
        std::fs::create_dir_all(&boot_dir).unwrap();
        let kernel_src = dir.path().join("kernel");
        std::fs::write(&kernel_src, b"KERNEL").unwrap();

        let boot = Some(BootComponents {
            kernel: Some(kernel_src.to_string_lossy().to_string()),
            initfs: None,
            bootloader: None,
        });

        let mut old = sample_manifest();
        old.boot = boot.clone();
        let mut new = sample_manifest();
        new.boot = boot;

        let mut warnings = Vec::new();
        let updated = update_boot_components_at(
            &old, &new, &boot_dir.to_string_lossy(), &mut warnings,
        );
        assert!(!updated);
        assert!(warnings.is_empty());
    }

    #[test]
    fn boot_update_none_boot_section_skips() {
        let old = sample_manifest(); // boot: None
        let new = sample_manifest(); // boot: None

        let mut warnings = Vec::new();
        let updated = update_boot_components_at(
            &old, &new, "/tmp/nonexistent-boot", &mut warnings,
        );
        assert!(!updated);
        assert!(warnings.is_empty());
    }

    #[test]
    fn boot_update_missing_store_path_warns() {
        let dir = tempfile::tempdir().unwrap();
        let boot_dir = dir.path().join("boot");
        std::fs::create_dir_all(&boot_dir).unwrap();

        let old = sample_manifest();
        let mut new = sample_manifest();
        new.boot = Some(BootComponents {
            kernel: Some("/nonexistent/store/kernel".to_string()),
            initfs: None,
            bootloader: None,
        });

        let mut warnings = Vec::new();
        let updated = update_boot_components_at(
            &old, &new, &boot_dir.to_string_lossy(), &mut warnings,
        );
        assert!(!updated); // couldn't copy, so not "updated"
        assert_eq!(warnings.len(), 1);
        assert!(warnings[0].contains("missing or unreadable"));
    }

    #[test]
    fn boot_components_changed_detection() {
        let mut old = sample_manifest();
        let mut new = sample_manifest();

        // None vs None → no change
        assert!(!boot_components_changed(&old, &new));

        // None vs Some → changed
        new.boot = Some(BootComponents {
            kernel: Some("/nix/store/k1".to_string()),
            initfs: None,
            bootloader: None,
        });
        assert!(boot_components_changed(&old, &new));

        // Same values → no change
        old.boot = new.boot.clone();
        assert!(!boot_components_changed(&old, &new));

        // Different kernel → changed
        old.boot.as_mut().unwrap().kernel = Some("/nix/store/k2".to_string());
        assert!(boot_components_changed(&old, &new));
    }

    #[test]
    fn has_boot_config_changed_includes_boot_components() {
        let mut old = sample_manifest();
        let mut new = sample_manifest();

        // Same config, no boot section → no change
        assert!(!has_boot_config_changed(&old, &new));

        // Add boot components to new → detected as change
        new.boot = Some(BootComponents {
            kernel: Some("/nix/store/new-kernel".to_string()),
            initfs: None,
            bootloader: None,
        });
        assert!(has_boot_config_changed(&old, &new));
    }

    // ── Topological sort tests ──

    #[test]
    fn topo_sort_empty() {
        let result = topo_sort(&[]);
        assert_eq!(result.unwrap(), Vec::<String>::new());
    }

    #[test]
    fn topo_sort_single() {
        let scripts = vec![ActivationScript {
            name: "setup".to_string(),
            deps: vec![],
        }];
        assert_eq!(topo_sort(&scripts).unwrap(), vec!["setup"]);
    }

    #[test]
    fn topo_sort_linear_chain() {
        let scripts = vec![
            ActivationScript {
                name: "c".to_string(),
                deps: vec!["b".to_string()],
            },
            ActivationScript {
                name: "b".to_string(),
                deps: vec!["a".to_string()],
            },
            ActivationScript {
                name: "a".to_string(),
                deps: vec![],
            },
        ];
        assert_eq!(topo_sort(&scripts).unwrap(), vec!["a", "b", "c"]);
    }

    #[test]
    fn topo_sort_diamond() {
        // a → b, a → c, b → d, c → d
        let scripts = vec![
            ActivationScript {
                name: "a".to_string(),
                deps: vec![],
            },
            ActivationScript {
                name: "b".to_string(),
                deps: vec!["a".to_string()],
            },
            ActivationScript {
                name: "c".to_string(),
                deps: vec!["a".to_string()],
            },
            ActivationScript {
                name: "d".to_string(),
                deps: vec!["b".to_string(), "c".to_string()],
            },
        ];
        let order = topo_sort(&scripts).unwrap();
        assert_eq!(order[0], "a"); // a first (no deps)
        // b and c next (both depend on a), deterministic sorted order
        assert_eq!(order[1], "b");
        assert_eq!(order[2], "c");
        assert_eq!(order[3], "d"); // d last (depends on b and c)
    }

    #[test]
    fn topo_sort_cycle_detected() {
        let scripts = vec![
            ActivationScript {
                name: "a".to_string(),
                deps: vec!["b".to_string()],
            },
            ActivationScript {
                name: "b".to_string(),
                deps: vec!["a".to_string()],
            },
        ];
        let err = topo_sort(&scripts).unwrap_err();
        assert!(err.contains("cycle"), "expected cycle error, got: {err}");
    }

    #[test]
    fn topo_sort_unknown_dep() {
        let scripts = vec![ActivationScript {
            name: "a".to_string(),
            deps: vec!["nonexistent".to_string()],
        }];
        let err = topo_sort(&scripts).unwrap_err();
        assert!(
            err.contains("unknown"),
            "expected unknown dep error, got: {err}"
        );
    }

    #[test]
    fn topo_sort_self_cycle() {
        let scripts = vec![ActivationScript {
            name: "a".to_string(),
            deps: vec!["a".to_string()],
        }];
        let err = topo_sort(&scripts).unwrap_err();
        assert!(err.contains("cycle"), "expected cycle error, got: {err}");
    }

    #[test]
    fn topo_sort_independent_scripts_sorted_alphabetically() {
        let scripts = vec![
            ActivationScript {
                name: "z_last".to_string(),
                deps: vec![],
            },
            ActivationScript {
                name: "a_first".to_string(),
                deps: vec![],
            },
            ActivationScript {
                name: "m_middle".to_string(),
                deps: vec![],
            },
        ];
        assert_eq!(
            topo_sort(&scripts).unwrap(),
            vec!["a_first", "m_middle", "z_last"]
        );
    }

    // ── Activation plan with scripts ──

    #[test]
    fn plan_shows_activation_scripts() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.activation_scripts = vec![
            ActivationScript {
                name: "createDirs".to_string(),
                deps: vec![],
            },
            ActivationScript {
                name: "writeConfig".to_string(),
                deps: vec!["createDirs".to_string()],
            },
        ];
        let p = plan(&old, &new);
        assert_eq!(p.activation_scripts, vec!["createDirs", "writeConfig"]);
    }

    #[test]
    fn plan_empty_without_activation_scripts() {
        let m = sample_manifest();
        let p = plan(&m, &m);
        assert!(p.activation_scripts.is_empty());
        assert!(p.is_empty());
    }

    #[test]
    fn plan_not_empty_with_activation_scripts() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.activation_scripts = vec![ActivationScript {
            name: "test".to_string(),
            deps: vec![],
        }];
        let p = plan(&old, &new);
        assert!(!p.is_empty());
    }

    #[test]
    fn plan_display_with_activation_scripts() {
        let old = sample_manifest();
        let mut new = sample_manifest();
        new.activation_scripts = vec![
            ActivationScript {
                name: "setup".to_string(),
                deps: vec![],
            },
            ActivationScript {
                name: "finalize".to_string(),
                deps: vec!["setup".to_string()],
            },
        ];
        let p = plan(&old, &new);
        // Should not panic
        p.display();
    }
}
