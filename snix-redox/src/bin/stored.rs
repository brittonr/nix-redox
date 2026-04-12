use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "stored", about = "Redox store scheme daemon")]
struct Cli {
    /// Local binary cache path for lazy extraction
    #[arg(long, default_value = "/nix/cache", env = "SNIX_CACHE_PATH")]
    cache_path: String,

    /// Store directory path
    #[arg(long, default_value = "/nix/store", env = "SNIX_STORE_DIR")]
    store_dir: String,
}

#[cfg(target_os = "redox")]
fn main() {
    let cli = Cli::parse();
    let config = snix_redox::stored::StoredConfig {
        cache_path: cli.cache_path,
        store_dir: cli.store_dir,
    };

    if let Err(err) = snix_redox::stored::scheme::run_daemon(config) {
        eprintln!("{err}");
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "redox"))]
fn main() {
    let _ = Cli::parse();
    eprintln!("stored is only supported on Redox");
    std::process::exit(1);
}
