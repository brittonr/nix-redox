# RedoxOS Boot Configuration
#
# Manages boot-related settings:
#   - Kernel package selection
#   - Bootloader package selection
#   - Initfs (initial RAM filesystem) configuration
#
# These options are consumed directly by:
#   - build/initfs.nix: Builds the initial RAM filesystem
#   - build/disk-image.nix: Assembles the bootable disk image
#
# This module does NOT contribute to config (no generatedFiles, etc.)
# as boot components are handled specially by the build layer.

{
  config,
  lib,
  pkgs,
  hostPkgs,
  redoxSystemLib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkDefault
    types
    ;

  cfg = config.redox.boot;

in
{
  options.redox.boot = {
    kernel = mkOption {
      type = types.nullOr types.package;
      default = pkgs.kernel or null;
      description = ''
        Kernel package to use for booting.
        Defaults to pkgs.kernel if available.
      '';
    };

    bootloader = mkOption {
      type = types.nullOr types.package;
      default = pkgs.bootloader or null;
      description = ''
        Bootloader package (RedoxOS UEFI bootloader).
        Defaults to pkgs.bootloader if available.
      '';
    };

    initfs = {
      extraBinaries = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Additional binaries from the base package to include in initfs.
          These are core system binaries needed early in boot.
        '';
        example = [
          "init"
          "ramfs"
          "nulld"
          "zerod"
        ];
      };

      extraDrivers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Additional driver binaries to include in initfs.
          Drivers must exist in the base package's bin directory.
        '';
        example = [
          "e1000d"
          "nvmed"
          "virtio-blkd"
        ];
      };

      enableGraphics = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Include graphics-related daemons in initfs.
          Enables vesad, inputd, and related services.
          Set automatically by redox.graphics.enable.
        '';
      };
    };
  };

  config = {
    # No config contributions - boot options are consumed by build modules
    # This keeps boot configuration separate from runtime system configuration
  };
}
