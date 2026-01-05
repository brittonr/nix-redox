# Flake-parts module for RedoxOS overlays
#
# This module exports overlays using easyOverlay for simplified generation.
# It provides automatic overlay creation from perSystem packages.
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
  imports = [
    inputs.flake-parts.flakeModules.easyOverlay
  ];

  perSystem =
    {
      config,
      pkgs,
      final,
      lib,
      ...
    }:
    {
      # Packages to include in the default overlay
      # easyOverlay automatically creates overlays.default from this
      overlayAttrs = {
        redox = {
          # Host tools
          inherit (config.packages)
            cookbook
            redoxfs
            installer
            fstools
            ;

          # System components
          inherit (config.packages)
            relibc
            kernel
            bootloader
            base
            sysroot
            ;

          # Userspace packages
          inherit (config.packages)
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
          inherit (config.packages)
            initfs
            diskImage
            runQemu
            runQemuGraphical
            ;

          # Rust toolchain for Redox
          rustToolchain = config._module.args.redoxToolchain.rustToolchain;

          # Library functions for advanced use
          lib = import ../lib {
            inherit pkgs lib;
            redoxTarget = config.redox._computed.redoxTarget;
          };
        };
      };
    };
}
