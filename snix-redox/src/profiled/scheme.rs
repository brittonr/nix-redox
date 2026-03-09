//! Redox scheme protocol implementation for `profiled`.
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]`).
//! Bridges the kernel scheme protocol to the profile mapping logic.

use super::{ProfileDaemon, ProfiledConfig};

/// Run the profile scheme daemon (blocking).
pub fn run_daemon(config: ProfiledConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!(
        "profiled: initializing (profiles={}, store={})",
        config.profiles_dir, config.store_dir
    );

    let daemon = ProfileDaemon::new(config)?;

    let profile_count = daemon.profiles.list_profiles().len();
    eprintln!("profiled: loaded {profile_count} profiles");

    // Scheme registration follows the same pattern as stored.
    // See stored/scheme.rs for the full commented implementation plan.
    //
    // The SchemeSync implementation will:
    //   openat("default/bin/rg") → resolve through mapping → open underlying file
    //   openat("default/.control") → return a control handle for write commands
    //   read(file_handle) → read from resolved file
    //   write(control_handle) → process_control() JSON command
    //   getdents("default/bin/") → list_union("bin") across all packages
    //   fpath(id) → "profile:{scheme_path}"

    eprintln!("profiled: scheme registration requires redox_scheme crate");
    Err("profiled: scheme registration not yet implemented for this target".into())
}
