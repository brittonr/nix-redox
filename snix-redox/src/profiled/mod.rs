//! `profiled` — Profile scheme daemon for Redox OS.
//!
//! Presents a union view of installed packages via the `profile:` scheme.
//! No symlinks — package add/remove updates an in-memory mapping table.
//!
//! Architecture:
//!   1. Registers as the `profile` scheme with the Redox kernel
//!   2. Loads profile mappings from `/nix/var/snix/profiles/{name}/mapping.json`
//!   3. Resolves `profile:default/bin/rg` by searching installed packages
//!   4. Mutations via `.control` write interface (add/remove packages)
//!
//! Paths:
//! ```text
//! profile:                          → list all profiles
//! profile:default/                  → list union of all package roots
//! profile:default/bin/              → union of all bin/ dirs
//! profile:default/bin/rg            → resolved to store:abc.../bin/rg
//! profile:default/.control          → write JSON commands to mutate
//! ```

pub mod mapping;

#[cfg(target_os = "redox")]
pub mod scheme;

/// Configuration for the profile daemon.
#[derive(Debug, Clone)]
pub struct ProfiledConfig {
    /// Base directory for profile data.
    /// Default: `/nix/var/snix/profiles`
    pub profiles_dir: String,
    /// Store directory for resolving package paths.
    /// Default: `/nix/store`
    pub store_dir: String,
}

impl Default for ProfiledConfig {
    fn default() -> Self {
        Self {
            profiles_dir: "/nix/var/snix/profiles".to_string(),
            store_dir: "/nix/store".to_string(),
        }
    }
}

/// Core state for the profile daemon.
pub struct ProfileDaemon {
    /// Profile mappings keyed by profile name.
    pub profiles: mapping::ProfileStore,
    /// Daemon configuration.
    pub config: ProfiledConfig,
}

impl ProfileDaemon {
    /// Create a new profile daemon, loading existing mappings from disk.
    pub fn new(config: ProfiledConfig) -> Result<Self, Box<dyn std::error::Error>> {
        let profiles = mapping::ProfileStore::load(&config.profiles_dir)?;
        Ok(Self { profiles, config })
    }

    /// Create a profile daemon for testing with a custom profiles directory.
    #[cfg(test)]
    pub fn new_at(
        profiles_dir: &str,
        store_dir: &str,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let config = ProfiledConfig {
            profiles_dir: profiles_dir.to_string(),
            store_dir: store_dir.to_string(),
        };
        let profiles = mapping::ProfileStore::load(&config.profiles_dir)?;
        Ok(Self { profiles, config })
    }
}

/// Entry point for `snix profiled` — runs the scheme daemon.
pub fn run(config: ProfiledConfig) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "redox")]
    {
        scheme::run_daemon(config)
    }

    #[cfg(not(target_os = "redox"))]
    {
        let _ = config;
        Err("profiled: scheme daemons are only supported on Redox OS".into())
    }
}
