# Flake-parts module for RedoxOS overlays
#
# This module exports overlays that can be used by other flakes
# to access RedoxOS packages and toolchains.
#
# Usage in other flakes:
#   {
#     inputs.redox.url = "github:user/redox";
#
#     outputs = { nixpkgs, redox, ... }: {
#       # Apply overlay to get redox packages
#       pkgs = import nixpkgs {
#         overlays = [ redox.overlays.default ];
#       };
#
#       # Access via pkgs.redox.*
#     };
#   }

{ self, inputs, ... }:

{
  flake = {
    overlays = {
      # Default overlay - provides redox packages and toolchain
      default =
        final: prev:
        let
          pkgsWithRustOverlay = import inputs.nixpkgs {
            inherit (prev) system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };
        in
        {
          redox = {
            # Rust toolchain configured for Redox
            rustToolchain = pkgsWithRustOverlay.rust-bin.nightly."2025-10-03".default.override {
              extensions = [
                "rust-src"
                "rustfmt"
                "clippy"
              ];
              targets = [ "x86_64-unknown-redox" ];
            };

            # Host tools (run on build machine)
            inherit (self.packages.${prev.system})
              cookbook
              redoxfs
              installer
              fstools
              ;

            # System components
            inherit (self.packages.${prev.system})
              relibc
              kernel
              bootloader
              base
              sysroot
              ;

            # Userspace packages
            inherit (self.packages.${prev.system})
              ion
              helix
              binutils
              extrautils
              sodium
              netutils
              uutils
              redoxfsTarget
              ;

            # Infrastructure
            inherit (self.packages.${prev.system})
              initfs
              diskImage
              runQemu
              runQemuGraphical
              ;

            # Library functions
            lib = import ../lib {
              pkgs = prev;
              inherit (prev) lib;
              redoxTarget = "x86_64-unknown-redox";
            };
          };
        };

      # Minimal overlay - just the rust toolchain
      toolchain =
        final: prev:
        let
          pkgsWithRustOverlay = import inputs.nixpkgs {
            inherit (prev) system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };
        in
        {
          redox-toolchain = pkgsWithRustOverlay.rust-bin.nightly."2025-10-03".default.override {
            extensions = [
              "rust-src"
              "rustfmt"
              "clippy"
            ];
            targets = [ "x86_64-unknown-redox" ];
          };
        };
    };
  };
}
