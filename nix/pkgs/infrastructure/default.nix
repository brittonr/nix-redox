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

  # QEMU runners factory - requires diskImage and bootloader
  mkQemuRunners =
    { diskImage, bootloader }:
    import ./qemu-runners.nix {
      inherit
        pkgs
        lib
        diskImage
        bootloader
        ;
    };

  # Cloud Hypervisor runners factory - requires diskImage only
  # (bootloader is loaded from ESP partition on disk)
  # Optional diskImageNet for network-optimized image with static IP config
  mkCloudHypervisorRunners =
    {
      diskImage,
      diskImageNet ? null,
    }:
    import ./cloud-hypervisor-runners.nix {
      inherit
        pkgs
        lib
        diskImage
        diskImageNet
        ;
    };

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
      # Network configuration mode: "auto" | "dhcp" | "static" | "none"
      networkMode ? "auto",
      # Static IP configuration (for "static" or "auto" fallback)
      staticNetworkConfig ? {
        ip = "172.16.0.2";
        netmask = "255.255.255.0";
        gateway = "172.16.0.1";
      },
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
        networkMode
        staticNetworkConfig
        ;
      inherit (args) redoxfs;
    };
}
