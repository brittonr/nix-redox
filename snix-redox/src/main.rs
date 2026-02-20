//! snix — Nix evaluator and binary cache client for Redox OS
//!
//! Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
//! Uses ureq for sync HTTP — no tokio runtime needed.

mod eval;
mod cache;
mod store;
mod nar;
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
    },

    /// Show info about a store path from a binary cache
    PathInfo {
        /// Store path to look up
        store_path: String,

        /// Binary cache URL
        #[arg(short, long, default_value = "https://cache.nixos.org")]
        cache_url: String,
    },

    /// Verify the local Nix store
    StoreVerify,

    /// Interactive REPL for Nix expressions
    Repl,

    /// System introspection (info, verify, diff)
    System {
        #[command(subcommand)]
        command: SystemCommand,
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
        Command::Eval { expr, file } => eval::run(expr, file),
        Command::ShowDerivation { path } => eval::show_derivation(&path),
        Command::Fetch {
            store_path,
            cache_url,
        } => cache::fetch(&store_path, &cache_url),
        Command::PathInfo {
            store_path,
            cache_url,
        } => cache::path_info(&store_path, &cache_url),
        Command::StoreVerify => store::verify(),
        Command::Repl => eval::repl(),
        Command::System { command } => match command {
            SystemCommand::Info { manifest } => {
                system::info(manifest.as_deref())
            }
            SystemCommand::Verify { verbose, manifest } => {
                system::verify(manifest.as_deref(), verbose)
            }
            SystemCommand::Diff { path } => system::diff(&path),
            SystemCommand::Generations { dir } => {
                system::generations(dir.as_deref())
            }
            SystemCommand::Switch { path, description, gen_dir, manifest } => {
                system::switch(&path, description.as_deref(), gen_dir.as_deref(), manifest.as_deref())
            }
            SystemCommand::Rollback { generation, dir, manifest } => {
                system::rollback(generation, dir.as_deref(), manifest.as_deref())
            }
        },
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
