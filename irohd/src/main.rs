#![cfg_attr(not(target_os = "redox"), allow(dead_code, unused_imports))]
//! irohd — iroh P2P networking scheme daemon for Redox OS
//!
//! Registers the `iroh` scheme and exposes P2P QUIC networking
//! through Redox file operations:
//!
//!   iroh:node           — read returns this node's endpoint ID
//!   iroh:peers/         — directory listing of known peers
//!   iroh:peers/<name>   — read=recv messages, write=send messages
//!   iroh:blobs/<hash>   — read fetches content-addressed data
//!   iroh:tickets/<t>    — read fetches blob by ticket
//!   iroh:.control       — JSON command interface

mod bridge;
mod config;
mod handles;
mod scheme;

fn main() {
    eprintln!("irohd: starting");

    let args: Vec<String> = std::env::args().collect();
    let config = match config::IrohConfig::from_args(&args[1..]) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("irohd: failed to load config: {e}");
            eprintln!("usage: irohd [--key-path PATH] [--peers-path PATH]");
            std::process::exit(1);
        }
    };

    if let Err(e) = scheme::run_daemon(config) {
        eprintln!("irohd: fatal: {e}");
        std::process::exit(1);
    }
}
