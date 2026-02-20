//! snix — Nix evaluator, binary cache client, and store manager for Redox OS
//!
//! Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
//! Uses ureq for sync HTTP — no tokio runtime needed.
//!
//! Store layout:
//!   /nix/store/              — store paths (the data)
//!   /nix/var/snix/pathinfo/  — per-path metadata (JSON)
//!   /nix/var/snix/gcroots/   — GC root symlinks

mod cache;
mod eval;
mod install;
mod local_cache;
mod nar;
mod pathinfo;
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

    /// Install a package from the local binary cache
    Install {
        /// Package name (as listed in `snix search`)
        name: String,

        /// Path to local binary cache
        #[arg(short, long, default_value = "/nix/cache")]
        cache_path: String,
    },

    /// Remove an installed package from the profile
    Remove {
        /// Package name to remove
        name: String,
    },

    /// Search available packages in the local binary cache
    Search {
        /// Optional search pattern (substring match)
        pattern: Option<String>,

        /// Path to local binary cache
        #[arg(short, long, default_value = "/nix/cache")]
        cache_path: String,
    },

    /// Show detailed info about a cached package
    Show {
        /// Package name
        name: String,

        /// Path to local binary cache
        #[arg(short, long, default_value = "/nix/cache")]
        cache_path: String,
    },

    /// Manage installed package profiles
    Profile {
        #[command(subcommand)]
        command: ProfileCommand,
    },

    /// Interactive REPL for Nix expressions
    Repl,

    /// System introspection (info, verify, diff)
    System {
        #[command(subcommand)]
        command: SystemCommand,
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
        /// Path to the new manifest.json to activate
        path: String,

        /// Description for this generation (e.g. "added ripgrep")
        #[arg(short = 'D', long)]
        description: Option<String>,

        /// Path to generations directory
        #[arg(short, long)]
        gen_dir: Option<String>,

        /// Path to current manifest file
        #[arg(short, long)]
        manifest: Option<String>,
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
}

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Eval { expr, file, raw } => eval::run(expr, file, raw),
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
        Command::Install { name, cache_path } => install::install(&name, &cache_path),
        Command::Remove { name } => install::remove(&name),
        Command::Search {
            pattern,
            cache_path,
        } => local_cache::search(&cache_path, pattern.as_deref()),
        Command::Show { name, cache_path } => install::show(&name, &cache_path),
        Command::Profile { command } => match command {
            ProfileCommand::List => install::list_profile(),
        },
        Command::Repl => eval::repl(),
        Command::System { command } => match command {
            SystemCommand::Info { manifest } => system::info(manifest.as_deref()),
            SystemCommand::Verify { verbose, manifest } => {
                system::verify(manifest.as_deref(), verbose)
            }
            SystemCommand::Diff { path } => system::diff(&path),
            SystemCommand::Generations { dir } => system::generations(dir.as_deref()),
            SystemCommand::Switch {
                path,
                description,
                gen_dir,
                manifest,
            } => system::switch(
                &path,
                description.as_deref(),
                gen_dir.as_deref(),
                manifest.as_deref(),
            ),
            SystemCommand::Rollback {
                generation,
                dir,
                manifest,
            } => system::rollback(generation, dir.as_deref(), manifest.as_deref()),
        },
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
