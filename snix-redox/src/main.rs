//! snix — Nix evaluator and binary cache client for Redox OS
//!
//! Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
//! Uses ureq for sync HTTP — no tokio runtime needed.

mod eval;
mod cache;
mod store;
mod nar;

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
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
