# Infrastructure packages for RedoxOS
#
# This module provides boot infrastructure components:
# - initfs-tools: Host tools for creating initfs archives
# - bootstrap: Minimal loader prepended to initfs
# - initfs: Complete initial RAM filesystem image
# - disk-image: Bootable UEFI disk image
#
# Usage:
#   infrastructure = import ./nix/pkgs/infrastructure {
#     inherit pkgs lib rustToolchain sysrootVendor redoxTarget vendor;
#     inherit base-src relibc-src;
#     systemPkgs = { inherit kernel bootloader base; };
#     userspacePkgs = { inherit ion helix binutils extrautils sodium netutils uutils redoxfsTarget; };
#   };
#
#   inherit (infrastructure) initfsTools bootstrap initfs diskImage;

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget ? "x86_64-unknown-redox",
  vendor,
  base-src,
  relibc-src,
  # Host redoxfs tool (for creating RedoxFS images)
  redoxfs ? null,
  # System packages required for boot
  systemPkgs ? { },
  # Userspace packages to include in rootfs
  userspacePkgs ? { },
}:

let
  # Import initfs-tools (host tool)
  initfsTools = import ./initfs-tools.nix {
    inherit
      pkgs
      lib
      rustToolchain
      base-src
      ;
  };

  # Import bootstrap (cross-compiled)
  bootstrap = import ./bootstrap.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      base-src
      relibc-src
      vendor
      ;
  };

in
{
  inherit initfsTools bootstrap;

  # initfs and diskImage require system and userspace packages
  # They're built on-demand when those packages are available
  mkInitfs =
    {
      base,
      ion,
      redoxfsTarget,
      netutils ? null,
      kernel ? null,
      bootloader ? null,
    }:
    import ./initfs.nix {
      inherit
        pkgs
        lib
        initfsTools
        bootstrap
        ;
      inherit
        base
        ion
        redoxfsTarget
        netutils
        ;
    };

  mkDiskImage =
    {
      kernel,
      bootloader,
      initfs,
      base,
      ion,
      helix ? null,
      binutils ? null,
      extrautils ? null,
      sodium ? null,
      netutils ? null,
      uutils ? null,
      # Allow caller to override redoxfs if needed
      redoxfs ? redoxfs,
    }@args:
    assert args.redoxfs != null;
    import ./disk-image.nix {
      inherit pkgs lib;
      inherit kernel bootloader initfs;
      inherit
        base
        ion
        helix
        binutils
        extrautils
        sodium
        netutils
        uutils
        ;
      inherit (args) redoxfs;
    };
}
