# Flake-parts module for Rust toolchain configuration
#
# This module centralizes the Rust toolchain setup for RedoxOS builds.
# It provides a nightly Rust toolchain configured with the Redox target
# and all necessary extensions for cross-compilation.
#
# The toolchain is shared across all modules via _module.args.redoxToolchain
#
# Usage:
#   perSystem = { config, ... }: {
#     # Access toolchain
#     packages.foo = mkDerivation {
#       nativeBuildInputs = [ config._module.args.redoxToolchain.rustToolchain ];
#     };
#   };

{ inputs, ... }:

{
  perSystem =
    {
      pkgs,
      system,
      config,
      ...
    }:
    let
      # Import nixpkgs with rust-overlay
      pkgsWithOverlay = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
      };

      # Get configuration from config.nix module
      redoxCfg = config.redox.config;

      # Compute target triple from config
      redoxTarget = "${redoxCfg.targetArch}-unknown-redox";

      # Nightly Rust toolchain with Redox target
      rustToolchain = pkgsWithOverlay.rust-bin.nightly.${redoxCfg.rustNightlyDate}.default.override {
        extensions = [
          "rust-src"
          "rustfmt"
          "clippy"
          "rust-analyzer"
        ];
        targets = [ redoxTarget ];
      };

      # Crane for building Rust packages
      craneLib = (inputs.crane.mkLib pkgsWithOverlay).overrideToolchain rustToolchain;

    in
    {
      # Expose toolchain configuration for other modules
      _module.args.redoxToolchain = {
        inherit
          rustToolchain
          craneLib
          pkgsWithOverlay
          redoxTarget
          ;
      };
    };
}
