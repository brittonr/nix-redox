//! snix — Nix evaluator, binary cache client, and store manager for Redox OS
//!
//! Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
//! Uses ureq for sync HTTP — no tokio runtime needed.
//!
//! Store layout:
//!   /nix/store/              — store paths (the data)
//!   /nix/var/snix/pathinfo/  — per-path metadata (JSON)
//!   /nix/var/snix/gcroots/   — GC root symlinks

mod activate;
mod bridge;
mod bridge_build;
mod build_proxy;
mod cache;
mod cache_source;
mod channel;
mod derivation_builtins;
mod eval;
mod fetchers;
mod file_io_worker;
mod flake;
mod local_build;
mod profiled;
mod sandbox;
mod snix_io;
mod stored;
mod vendor;
mod install;
mod known_paths;
mod local_cache;
mod nar;
mod pathinfo;
mod rebuild;
mod store;
mod system;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "snix", version, about = "Nix for Redox OS")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Evaluate a Nix expression and print the result
    Eval {
        /// Nix expression to evaluate
        #[arg(short, long)]
        expr: Option<String>,

        /// File to evaluate
        #[arg(short, long)]
        file: Option<String>,

        /// Print raw string value (strip quotes, no escaping)
        #[arg(long)]
        raw: bool,
    },

    /// Build a derivation (evaluate + execute builder)
    ///
    /// Supports three modes:
    ///   snix build .#ripgrep           — flake installable (new!)
    ///   snix build --expr '...'        — Nix expression
    ///   snix build --file path.nix     — Nix file
    Build {
        /// Flake installable (e.g., `.#ripgrep`, `path#package`)
        #[arg(index = 1)]
        installable: Option<String>,

        /// Nix expression to build (must evaluate to a derivation)
        #[arg(short, long)]
        expr: Option<String>,

        /// File containing a Nix expression to build
        #[arg(short, long)]
        file: Option<String>,

        /// Flake attribute to build via bridge (e.g., "ripgrep")
        #[arg(short, long)]
        attr: Option<String>,

        /// Delegate build to host via bridge (virtio-fs shared filesystem)
        #[arg(long)]
        bridge: bool,

        /// Shared directory for bridge communication (default: /scheme/shared)
        #[arg(long)]
        shared_dir: Option<String>,

        /// Bridge timeout in seconds (default: 300)
        #[arg(long)]
        timeout: Option<u64>,

        /// Disable namespace sandboxing for the build (run unsandboxed)
        #[arg(long)]
        no_sandbox: bool,
    },

    /// Show a derivation in human-readable form
    ShowDerivation {
        /// Path to .drv file
        path: String,
    },

    /// Fetch a store path from a binary cache
    Fetch {
        /// Store path to fetch (e.g. /nix/store/abc...-hello-2.12.1)
        store_path: String,

        /// Binary cache URL
        #[arg(short, long, default_value = "https://cache.nixos.org")]
        cache_url: String,

        /// Recursively fetch all dependencies (full closure)
        #[arg(short, long)]
        recursive: bool,
    },

    /// Show info about a store path from a binary cache
    PathInfo {
        /// Store path to look up
        store_path: String,

        /// Binary cache URL
        #[arg(short, long, default_value = "https://cache.nixos.org")]
        cache_url: String,
    },

    /// Local store operations
    Store {
        #[command(subcommand)]
        command: StoreCommand,
    },

    /// Install a package from a binary cache (local or remote)
    Install {
        /// Package name (as listed in `snix search`)
        name: String,

        /// Remote binary cache URL (e.g., http://10.0.2.2:8080)
        #[arg(long)]
        cache_url: Option<String>,

        /// Path to local binary cache (also: SNIX_CACHE_PATH env var)
        #[arg(short, long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
        cache_path: String,

        /// Recursively fetch all dependencies
        #[arg(short, long)]
        recursive: bool,

        /// Lazy install: register without extracting (requires stored daemon)
        #[arg(long)]
        lazy: bool,
    },

    /// Remove an installed package from the profile
    Remove {
        /// Package name to remove
        name: String,
    },

    /// Search available packages in a binary cache (local or remote)
    Search {
        /// Optional search pattern (substring match)
        pattern: Option<String>,

        /// Remote binary cache URL (e.g., http://10.0.2.2:8080)
        #[arg(long)]
        cache_url: Option<String>,

        /// Path to local binary cache (also: SNIX_CACHE_PATH env var)
        #[arg(short, long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
        cache_path: String,
    },

    /// Show detailed info about a cached package (local or remote)
    Show {
        /// Package name
        name: String,

        /// Remote binary cache URL (e.g., http://10.0.2.2:8080)
        #[arg(long)]
        cache_url: Option<String>,

        /// Path to local binary cache (also: SNIX_CACHE_PATH env var)
        #[arg(short, long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
        cache_path: String,
    },

    /// Manage installed package profiles
    Profile {
        #[command(subcommand)]
        command: ProfileCommand,
    },

    /// Interactive REPL for Nix expressions
    Repl,

    /// Manage Cargo vendor directories for offline builds
    Vendor {
        #[command(subcommand)]
        command: vendor::VendorCommand,
    },

    /// System introspection (info, verify, diff)
    System {
        #[command(subcommand)]
        command: SystemCommand,
    },

    /// Manage remote update channels
    Channel {
        #[command(subcommand)]
        command: ChannelCommand,
    },

    /// Run the store scheme daemon (Redox only)
    ///
    /// Registers the `store:` scheme and serves /nix/store/ paths
    /// with lazy NAR extraction on first access.
    Stored {
        /// Local binary cache path for lazy extraction
        #[arg(long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
        cache_path: String,

        /// Store directory path
        #[arg(long, default_value = "/nix/store")]
        store_dir: String,
    },

    /// Run the profile scheme daemon (Redox only)
    ///
    /// Registers the `profile:` scheme and presents union views
    /// of installed packages (no symlinks needed).
    Profiled {
        /// Profiles directory
        #[arg(long, default_value = "/nix/var/snix/profiles")]
        profiles_dir: String,

        /// Store directory path
        #[arg(long, default_value = "/nix/store")]
        store_dir: String,
    },
}

#[derive(Subcommand)]
enum StoreCommand {
    /// Verify the local Nix store (check path names)
    Verify,

    /// List all registered store paths with sizes
    List,

    /// Show metadata for a registered store path
    Info {
        /// Store path to look up
        path: String,
    },

    /// Show the transitive closure (all dependencies) of a store path
    Closure {
        /// Root store path
        path: String,
    },

    /// Run garbage collection (delete unreferenced paths)
    Gc {
        /// Show what would be deleted without actually deleting
        #[arg(long)]
        dry_run: bool,
    },

    /// Add a GC root (protect a path from garbage collection)
    AddRoot {
        /// Symbolic name for the root (e.g. "my-app", "system")
        name: String,

        /// Store path to protect
        path: String,
    },

    /// Remove a GC root
    RemoveRoot {
        /// Name of the root to remove
        name: String,
    },

    /// List all GC roots
    Roots,
}

#[derive(Subcommand)]
enum ProfileCommand {
    /// List installed packages
    List,

    /// Install a package into the user profile
    Install {
        /// Package name (as listed in `snix search`)
        name: String,

        /// Remote binary cache URL (e.g., http://10.0.2.2:8080)
        #[arg(long)]
        cache_url: Option<String>,

        /// Path to local binary cache (also: SNIX_CACHE_PATH env var)
        #[arg(short, long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
        cache_path: String,

        /// Recursively fetch all dependencies
        #[arg(short, long)]
        recursive: bool,
    },

    /// Remove a package from the user profile
    Remove {
        /// Package name to remove
        name: String,
    },

    /// Show detailed info about a package
    Show {
        /// Package name
        name: String,

        /// Remote binary cache URL (e.g., http://10.0.2.2:8080)
        #[arg(long)]
        cache_url: Option<String>,

        /// Path to local binary cache (also: SNIX_CACHE_PATH env var)
        #[arg(short, long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
        cache_path: String,
    },
}

#[derive(Subcommand)]
enum SystemCommand {
    /// Display system information from the embedded manifest
    Info {
        /// Path to manifest file (default: /etc/redox-system/manifest.json)
        #[arg(short, long)]
        manifest: Option<String>,
    },

    /// Verify all tracked files against manifest hashes
    Verify {
        /// Show each verified file
        #[arg(short, long)]
        verbose: bool,

        /// Path to manifest file (default: /etc/redox-system/manifest.json)
        #[arg(short, long)]
        manifest: Option<String>,
    },

    /// Compare current system manifest with another
    Diff {
        /// Path to the other manifest.json to compare against
        path: String,
    },

    /// List all system generations
    Generations {
        /// Path to generations directory (default: /etc/redox-system/generations)
        #[arg(short, long)]
        dir: Option<String>,
    },

    /// Switch to a new system manifest, saving current as a generation
    Switch {
        /// Path to the new manifest.json to activate (or omit if using --channel)
        path: Option<String>,

        /// Switch to a named channel's manifest instead of a file path
        #[arg(long)]
        channel: Option<String>,

        /// Description for this generation (e.g. "added ripgrep")
        #[arg(short = 'D', long)]
        description: Option<String>,

        /// Only show what would change, don't modify anything
        #[arg(long)]
        dry_run: bool,

        /// Path to generations directory
        #[arg(short, long)]
        gen_dir: Option<String>,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,
    },

    /// Show activation plan (dry-run: what would change on switch)
    Activate {
        /// Path to the new manifest.json to activate
        path: String,

        /// Only show what would change, don't modify anything
        #[arg(long)]
        dry_run: bool,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,
    },

    /// Upgrade the system from a channel (fetch manifest, install packages, activate)
    Upgrade {
        /// Channel name to upgrade from (default: first registered channel)
        channel: Option<String>,

        /// Only show what would change, don't apply
        #[arg(long)]
        dry_run: bool,

        /// Skip confirmation prompt (auto-accept)
        #[arg(short = 'y', long)]
        yes: bool,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,

        /// Path to generations directory
        #[arg(short, long)]
        gen_dir: Option<String>,
    },

    /// Rollback to a previous generation
    Rollback {
        /// Generation number to roll back to (default: previous)
        #[arg(short, long)]
        generation: Option<u32>,

        /// Path to generations directory
        #[arg(short, long)]
        dir: Option<String>,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,
    },

    /// Activate a generation at boot time (no new generation created)
    ActivateBoot {
        /// Generation number to activate (reads /boot/default-generation if omitted)
        #[arg(short, long)]
        generation: Option<u32>,

        /// Path to generations directory
        #[arg(short, long)]
        dir: Option<String>,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,

        /// Path to boot default marker file
        #[arg(short, long)]
        boot_default: Option<String>,
    },

    /// Show or set which generation to boot next
    Boot {
        /// Generation number to boot next (omit to show current)
        generation: Option<u32>,

        /// Path to generations directory
        #[arg(short, long)]
        dir: Option<String>,

        /// Path to boot default marker file
        #[arg(short, long)]
        boot_default: Option<String>,
    },

    /// Rebuild system from configuration.nix (like nixos-rebuild switch)
    Rebuild {
        /// Path to configuration.nix (default: /etc/redox-system/configuration.nix)
        #[arg(short, long)]
        config: Option<String>,

        /// Only show what would change, don't apply
        #[arg(long)]
        dry_run: bool,

        /// Initialize a default configuration.nix
        #[arg(long)]
        init: bool,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,

        /// Path to generations directory
        #[arg(short, long)]
        gen_dir: Option<String>,

        /// Path to binary cache package index
        #[arg(long)]
        cache_index: Option<String>,

        /// Rebuild via bridge: send config to host, host builds, guest activates
        #[arg(long, conflicts_with = "local")]
        bridge: bool,

        /// Force local rebuild path (even for package changes)
        #[arg(long, conflicts_with = "bridge")]
        local: bool,

        /// Shared directory for bridge communication (default: /scheme/shared)
        #[arg(long)]
        shared_dir: Option<String>,

        /// Timeout in seconds for bridge build (default: 300)
        #[arg(long)]
        timeout: Option<u64>,
    },

    /// Show parsed configuration.nix without applying
    ShowConfig {
        /// Path to configuration.nix
        #[arg(short, long)]
        config: Option<String>,
    },

    /// Delete old generations (frees them for garbage collection)
    DeleteGenerations {
        /// Selector: "old" (all but current), "+N" (keep last N), "Nd" (older than N days), or space-separated IDs
        selector: Vec<String>,

        /// Show what would be deleted without actually deleting
        #[arg(long)]
        dry_run: bool,

        /// Path to generations directory
        #[arg(short, long)]
        dir: Option<String>,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,

        /// Path to boot default marker file
        #[arg(short, long)]
        boot_default: Option<String>,
    },

    /// Garbage collect: prune old generations then sweep unreferenced store paths
    Gc {
        /// Keep the last N generations (default: keep only current)
        #[arg(long)]
        keep: Option<u32>,

        /// Show what would be deleted without actually deleting
        #[arg(long)]
        dry_run: bool,

        /// Path to generations directory
        #[arg(short, long)]
        dir: Option<String>,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,

        /// Path to boot default marker file
        #[arg(short, long)]
        boot_default: Option<String>,
    },
}

#[derive(Subcommand)]
enum ChannelCommand {
    /// Add a new channel
    Add {
        /// Channel name (e.g. "stable", "unstable")
        name: String,

        /// Channel URL (points to a directory with manifest.json)
        url: String,
    },

    /// Remove a channel
    Remove {
        /// Channel name
        name: String,
    },

    /// List registered channels
    List,

    /// Fetch/update a channel's manifest
    Update {
        /// Channel name (or omit to update all)
        name: Option<String>,
    },
}

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Eval { expr, file, raw } => eval::run(expr, file, raw),
        Command::Build {
            installable,
            expr,
            file,
            attr,
            bridge,
            shared_dir,
            timeout,
            no_sandbox,
        } => {
            // Check if we got a flake installable (contains '#')
            if let Some(ref inst_str) = installable {
                if let Some(inst) = flake::parse_installable(inst_str) {
                    if bridge {
                        // Delegate to host via bridge
                        bridge_build::run(None, None, Some(inst.attr_path), shared_dir, timeout)
                    } else {
                        flake::build_flake_installable(&inst)
                    }
                } else {
                    Err(format!(
                        "invalid installable '{}' (expected format: .#attr or path#attr)",
                        inst_str
                    )
                    .into())
                }
            } else if bridge {
                bridge_build::run(expr, file, attr, shared_dir, timeout)
            } else {
                local_build::run_with_options(expr, file, no_sandbox)
            }
        }
        Command::ShowDerivation { path } => eval::show_derivation(&path),
        Command::Fetch {
            store_path,
            cache_url,
            recursive,
        } => {
            if recursive {
                cache::fetch_recursive(&store_path, &cache_url)
            } else {
                cache::fetch(&store_path, &cache_url)
            }
        }
        Command::PathInfo {
            store_path,
            cache_url,
        } => cache::path_info(&store_path, &cache_url),
        Command::Store { command } => match command {
            StoreCommand::Verify => store::verify(),
            StoreCommand::List => store::list_registered(),
            StoreCommand::Info { path } => store::show_info(&path),
            StoreCommand::Closure { path } => store::show_closure(&path),
            StoreCommand::Gc { dry_run } => store::run_gc(dry_run),
            StoreCommand::AddRoot { name, path } => store::add_root(&name, &path),
            StoreCommand::RemoveRoot { name } => store::remove_root(&name),
            StoreCommand::Roots => store::list_roots(),
        },
        Command::Install {
            name,
            cache_url,
            cache_path,
            recursive,
            lazy,
        } => {
            let source = cache_source::CacheSource::from_args(
                cache_url.as_deref(),
                Some(&cache_path),
            );
            if recursive {
                install::install_recursive(&name, &source)
            } else {
                install::install_with_options(&name, &source, lazy)
            }
        }
        Command::Remove { name } => install::remove(&name),
        Command::Search {
            pattern,
            cache_url,
            cache_path,
        } => {
            let source = cache_source::CacheSource::from_args(
                cache_url.as_deref(),
                Some(&cache_path),
            );
            source.search(pattern.as_deref())
        }
        Command::Show {
            name,
            cache_url,
            cache_path,
        } => {
            let source = cache_source::CacheSource::from_args(
                cache_url.as_deref(),
                Some(&cache_path),
            );
            install::show(&name, &source)
        }
        Command::Profile { command } => match command {
            ProfileCommand::List => install::list_profile(),
            ProfileCommand::Install {
                name,
                cache_url,
                cache_path,
                recursive,
            } => {
                let source = cache_source::CacheSource::from_args(
                    cache_url.as_deref(),
                    Some(&cache_path),
                );
                if recursive {
                    install::install_recursive(&name, &source)
                } else {
                    install::install(&name, &source)
                }
            }
            ProfileCommand::Remove { name } => install::remove(&name),
            ProfileCommand::Show {
                name,
                cache_url,
                cache_path,
            } => {
                let source = cache_source::CacheSource::from_args(
                    cache_url.as_deref(),
                    Some(&cache_path),
                );
                install::show(&name, &source)
            }
        },
        Command::Repl => eval::repl(),
        Command::Vendor { command } => vendor::run(&command),
        Command::Channel { command } => match command {
            ChannelCommand::Add { name, url } => channel::add(&name, &url),
            ChannelCommand::Remove { name } => channel::remove(&name),
            ChannelCommand::List => channel::list(),
            ChannelCommand::Update { name } => match name {
                Some(n) => channel::update(&n),
                None => channel::update_all(),
            },
        },
        Command::System { command } => match command {
            SystemCommand::Info { manifest } => system::info(manifest.as_deref()),
            SystemCommand::Verify { verbose, manifest } => {
                system::verify(manifest.as_deref(), verbose)
            }
            SystemCommand::Diff { path } => system::diff(&path),
            SystemCommand::Generations { dir } => system::generations(dir.as_deref()),
            SystemCommand::Activate {
                path,
                dry_run,
                manifest,
            } => system::activate_cmd(&path, dry_run, manifest.as_deref()),
            SystemCommand::Switch {
                path,
                channel: channel_name,
                description,
                dry_run,
                gen_dir,
                manifest,
            } => {
                let resolved_path: Result<String, Box<dyn std::error::Error>> =
                    match (&path, &channel_name) {
                        (Some(p), _) => Ok(p.clone()),
                        (None, Some(ch)) => channel::get_manifest_path(ch)
                            .map(|p| p.to_string_lossy().to_string()),
                        (None, None) => {
                            Err("either a manifest path or --channel is required".into())
                        }
                    };
                match resolved_path {
                    Ok(p) => system::switch(
                        &p,
                        description.as_deref(),
                        dry_run,
                        gen_dir.as_deref(),
                        manifest.as_deref(),
                    ),
                    Err(e) => Err(e),
                }
            }
            SystemCommand::Upgrade {
                channel: channel_name,
                dry_run,
                yes,
                manifest,
                gen_dir,
            } => system::upgrade(
                channel_name.as_deref(),
                dry_run,
                yes,
                manifest.as_deref(),
                gen_dir.as_deref(),
            ),
            SystemCommand::Rollback {
                generation,
                dir,
                manifest,
            } => system::rollback(generation, dir.as_deref(), manifest.as_deref()),
            SystemCommand::ActivateBoot {
                generation,
                dir,
                manifest,
                boot_default,
            } => {
                // If no --generation given, read from boot default marker
                let gen_id = match generation {
                    Some(id) => Some(id),
                    None => match system::read_boot_default(boot_default.as_deref()) {
                        Ok(id) => id,
                        Err(e) => {
                            eprintln!("boot: warning: could not read boot default: {e}");
                            None
                        }
                    },
                };
                match gen_id {
                    Some(id) => {
                        // At boot time, log warning on failure but don't halt
                        if let Err(e) = system::activate_boot(id, dir.as_deref(), manifest.as_deref()) {
                            eprintln!("boot: warning: generation activation failed: {e}");
                        }
                        Ok(())
                    }
                    None => Ok(()), // No marker — nothing to do
                }
            }
            SystemCommand::Boot {
                generation,
                dir,
                boot_default,
            } => system::boot_cmd(generation, dir.as_deref(), boot_default.as_deref()),
            SystemCommand::Rebuild {
                config,
                dry_run,
                init,
                manifest,
                gen_dir,
                cache_index,
                bridge,
                local,
                shared_dir,
                timeout,
            } => {
                if init {
                    rebuild::init_config(config.as_deref())
                } else if bridge {
                    // Explicit --bridge: always use bridge path
                    bridge::rebuild_via_bridge(
                        config.as_deref(),
                        dry_run,
                        shared_dir.as_deref(),
                        timeout,
                        manifest.as_deref(),
                        gen_dir.as_deref(),
                    )
                } else if local {
                    // Explicit --local: always use local path
                    rebuild::rebuild(
                        config.as_deref(),
                        dry_run,
                        manifest.as_deref(),
                        gen_dir.as_deref(),
                        cache_index.as_deref(),
                    )
                } else {
                    // Auto-route: bridge for package changes, local for config-only
                    rebuild::auto_rebuild(
                        config.as_deref(),
                        dry_run,
                        manifest.as_deref(),
                        gen_dir.as_deref(),
                        cache_index.as_deref(),
                        shared_dir.as_deref(),
                        timeout,
                    )
                }
            }
            SystemCommand::ShowConfig { config } => {
                rebuild::show_config(config.as_deref())
            }
            SystemCommand::DeleteGenerations {
                selector,
                dry_run,
                dir,
                manifest,
                boot_default,
            } => {
                let selector_str = selector.join(" ");
                if selector_str.is_empty() {
                    eprintln!("Error: selector required: 'old', '+N', 'Nd', or generation IDs");
                    std::process::exit(1);
                }
                system::delete_generations(
                    &selector_str,
                    dry_run,
                    dir.as_deref(),
                    manifest.as_deref(),
                    boot_default.as_deref(),
                )?;
                Ok(())
            }
            SystemCommand::Gc {
                keep,
                dry_run,
                dir,
                manifest,
                boot_default,
            } => {
                system::system_gc(
                    keep,
                    dry_run,
                    dir.as_deref(),
                    manifest.as_deref(),
                    boot_default.as_deref(),
                )
            }
        },
        Command::Stored {
            cache_path,
            store_dir,
        } => stored::run(stored::StoredConfig {
            cache_path,
            store_dir,
        }),
        Command::Profiled {
            profiles_dir,
            store_dir,
        } => profiled::run(profiled::ProfiledConfig {
            profiles_dir,
            store_dir,
        }),
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
