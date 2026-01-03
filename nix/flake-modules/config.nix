# Flake-parts module for RedoxOS configuration options
#
# This module provides configuration options that can be overridden
# by consumers of the flake. All hardcoded values are centralized here.
#
# Usage:
#   perSystem = { config, ... }: {
#     redox.config = {
#       rustNightlyDate = "2025-10-03";
#       diskImageSize = 512;
#       espSize = 200;
#     };
#   };

{
  lib,
  flake-parts-lib,
  ...
}:

let
  inherit (lib) mkOption types;
  inherit (flake-parts-lib) mkPerSystemOption;

in
{
  options.perSystem = mkPerSystemOption (
    { config, ... }:
    {
      options.redox = {
        config = {
          # Rust toolchain configuration
          rustNightlyDate = mkOption {
            type = types.str;
            default = "2025-10-03";
            description = ''
              The Rust nightly version date to use.
              Should match the rust-toolchain.toml in the Redox source.
            '';
            example = "2025-10-03";
          };

          # Target architecture
          targetArch = mkOption {
            type = types.enum [
              "x86_64"
              "aarch64"
              "i586"
            ];
            default = "x86_64";
            description = ''
              The target architecture for cross-compilation.
              Currently only x86_64 is fully supported.
            '';
          };

          # Disk image configuration
          diskImageSize = mkOption {
            type = types.int;
            default = 512;
            description = ''
              Total disk image size in megabytes.
              Must be larger than espSize + minimum RedoxFS partition.
            '';
            example = 1024;
          };

          espSize = mkOption {
            type = types.int;
            default = 200;
            description = ''
              EFI System Partition size in megabytes.
              Must be large enough for bootloader, kernel, and initfs.
            '';
            example = 200;
          };

          # QEMU configuration
          qemuMemory = mkOption {
            type = types.int;
            default = 2048;
            description = ''
              Memory size for QEMU in megabytes.
            '';
            example = 4096;
          };

          qemuCpus = mkOption {
            type = types.int;
            default = 4;
            description = ''
              Number of CPUs for QEMU.
            '';
            example = 8;
          };

          # Feature flags
          enableNetworking = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Enable networking support in the disk image.
              Includes netutils and network daemons in initfs.
            '';
          };

          enableGraphics = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable graphics support (Orbital desktop).
              Note: Currently not fully implemented in Nix build.
            '';
          };
        };
      };
    }
  );

  config = {
    # Provide computed values based on config
    perSystem =
      { config, ... }:
      {
        redox._computed = {
          redoxTarget = "${config.redox.config.targetArch}-unknown-redox";
          uefiTarget = "${config.redox.config.targetArch}-unknown-uefi";
        };
      };
  };
}
