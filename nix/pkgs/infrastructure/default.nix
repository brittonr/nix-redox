# Infrastructure packages for RedoxOS
#
# This module provides:
# - initfs-tools: Host tools for creating initfs archives
# - bootstrap: Minimal loader prepended to initfs
# - mkQemuRunners: QEMU runner script factory
# - mkCloudHypervisorRunners: Cloud Hypervisor runner script factory
#
# Disk images and initfs are built by the module system (nix/redox-system/).

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
      vendor
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
}
