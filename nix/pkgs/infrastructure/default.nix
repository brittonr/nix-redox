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
  # Optional vmConfig from /virtualisation module for resource defaults
  mkQemuRunners =
    {
      diskImage,
      bootloader,
      vmConfig ? { },
    }:
    import ./qemu-runners.nix {
      inherit
        pkgs
        lib
        diskImage
        bootloader
        vmConfig
        ;
    };

  # Cloud Hypervisor runners factory - requires diskImage only
  # (bootloader is loaded from ESP partition on disk)
  # Optional diskImageNet for network-optimized image with static IP config
  # Optional vmConfig from /virtualisation module for resource defaults
  mkCloudHypervisorRunners =
    {
      diskImage,
      diskImageNet ? null,
      vmConfig ? { },
    }:
    import ./cloud-hypervisor-runners.nix {
      inherit
        pkgs
        lib
        diskImage
        diskImageNet
        vmConfig
        ;
    };

  # Boot test factory - requires diskImage and bootloader
  # Produces a script that boots the image and verifies milestones
  mkBootTest =
    { diskImage, bootloader }:
    import ./boot-test.nix {
      inherit
        pkgs
        lib
        diskImage
        bootloader
        ;
    };

  # Functional test factory - requires diskImage with test startup script
  # Produces a script that boots the image, watches for FUNC_TEST results
  mkFunctionalTest =
    { diskImage, bootloader }:
    import ./functional-test.nix {
      inherit
        pkgs
        lib
        diskImage
        bootloader
        ;
    };
}
