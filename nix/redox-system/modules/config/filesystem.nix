# RedoxOS Filesystem Configuration
#
# Manages filesystem structure:
#   - Extra directories to create in rootfs
#   - Device symlinks (/dev/random, /dev/null, etc.)
#   - Other special symlinks (ion -> sh, etc.)
#
# Redox uses scheme-based devices instead of traditional /dev nodes:
#   - /scheme/rand: Random number generator
#   - /scheme/null: Null device
#   - /scheme/zero: Zero device
#
# This module provides compatibility symlinks in /dev for traditional paths.
# The directory structure is consumed by build/rootfs.nix and build/disk-image.nix.

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
    mkDefault
    types
    ;

  cfg = config.redox.filesystem;

in
{
  options.redox.filesystem = {
    extraDirectories = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Additional directories to create in the root filesystem.
        User home directories are automatically added by the users module.
      '';
      example = [
        "/var/log"
        "/var/cache"
        "/tmp"
        "/opt"
      ];
    };

    devSymlinks = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Symlinks to create in /dev for compatibility.
        Maps /dev/NAME to scheme path.
      '';
    };

    specialSymlinks = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Other special symlinks to create in the filesystem.
        Format: { "path/to/link" = "target"; }
      '';
    };
  };

  config = {
    # Default device symlinks (Redox scheme -> /dev compatibility)
    redox.filesystem.devSymlinks = {
      urandom = mkDefault "/scheme/rand";
      random = mkDefault "/scheme/rand";
      null = mkDefault "/scheme/null";
      zero = mkDefault "/scheme/zero";
      full = mkDefault "/scheme/zero"; # Not exact match but close enough
    };

    # Default special symlinks
    redox.filesystem.specialSymlinks = {
      # Ion shell compatibility (some scripts expect /bin/sh)
      "bin/sh" = mkDefault "/bin/ion";
    };

    # Default directory structure
    # mkDefault on the whole list so users can override the entire set
    redox.filesystem.extraDirectories = mkDefault [
      # System directories
      "/root"
      "/home"
      "/tmp"
      "/var"
      "/var/log"
      "/var/tmp"
      # Standard FHS directories
      "/etc"
      "/bin"
      "/sbin"
      "/usr"
      "/usr/bin"
      "/usr/sbin"
      "/usr/lib"
      "/usr/share"
      # Redox-specific directories
      "/scheme"
      "/dev"
    ];
  };
}
