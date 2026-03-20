// Library crate — enables `cargo test` for modules that don't depend on
// the binary target (which is disabled for cross-compilation).
//
// The binary (`src/main.rs`) re-uses these modules directly.

pub mod activate;
pub mod bridge;
pub mod bridge_build;
pub mod build_proxy;
pub mod cache;
pub mod cache_source;
pub mod channel;
// derivation_builtins: deleted — replaced by upstream snix-glue::builtins
pub mod eval;
pub mod fetchers;
pub mod file_io_worker;
pub mod flake;
pub mod install;
// known_paths: deleted — replaced by upstream snix-glue::known_paths
pub mod local_build;
pub mod local_cache;
pub mod nar;
pub mod pathinfo;
pub mod profiled;
pub mod rebuild;
pub mod sandbox;
// pub mod snix_io; // Replaced by upstream snix_glue::snix_store_io
pub mod store;
pub mod stored;
pub mod system;
pub mod vendor;
