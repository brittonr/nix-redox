# Flake-parts module for RedoxOS packages
#
# This module exports all RedoxOS packages through the standard flake-parts
# interface. It organizes packages into categories for better discoverability.
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/packages.nix ];
#
# Access via:
#   self.packages.${system}.cookbook
#   self.packages.${system}.diskImage

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      system,
      lib,
      self',
      config,
      ...
    }:
    let
      # Get toolchain from the toolchain module
      inherit (config._module.args.redoxToolchain)
        rustToolchain
        craneLib
        redoxTarget
        ;

      # Get patched sources from the sources module
      inherit (config._module.args) patchedSources;

      # Import modular library for cross-compilation utilities
      redoxLib = import ../lib {
        inherit pkgs lib rustToolchain;
        inherit redoxTarget;
      };

      # Sysroot vendor from modular library (for -Z build-std)
      sysrootVendor = redoxLib.sysroot.vendor;

      # Source inputs for modular packages
      # Use patchedSources.base for base (includes Cloud Hypervisor patches)
      srcInputs = {
        inherit (inputs)
          relibc-src
          kernel-src
          redoxfs-src
          installer-src
          redox-src
          openlibm-src
          compiler-builtins-src
          dlmalloc-rs-src
          cc-rs-src
          redox-syscall-src
          object-src
          rmm-src
          redox-path-src
          fdt-src
          bootloader-src
          uefi-src
          liblibc-src
          orbclient-src
          rustix-redox-src
          drm-rs-src
          ion-src
          helix-src
          binutils-src
          extrautils-src
          sodium-src
          netutils-src
          uutils-src
          filetime-src
          libredox-src
          # Orbital graphics packages
          orbital-src
          orbdata-src
          orbterm-src
          orbutils-src
          orbfont-src
          orbimage-src
          ;
        # Use patched base source with Cloud Hypervisor support
        base-src = patchedSources.base;
      };

      # Import modular packages
      modularPkgs = import ../pkgs {
        inherit
          pkgs
          lib
          craneLib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inputs = srcInputs;
      };

      # Import sodium separately (special handling for orbclient)
      sodium = import ../pkgs/userspace/sodium.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) sodium-src orbclient-src;
      };

      # Import orbdata (data-only package, no compilation)
      orbdata = import ../pkgs/userspace/orbdata.nix {
        inherit pkgs lib;
        inherit (inputs) orbdata-src;
      };

      # Import orbital (display server) - vendor hash needs computation
      orbital = import ../pkgs/userspace/orbital.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs)
          orbital-src
          orbclient-src
          libredox-src
          relibc-src
          ;
        # Use patched base source with Cloud Hypervisor support
        base-src = patchedSources.base;
      };

      # Import orbterm (terminal emulator) - vendor hash needs computation
      orbterm = import ../pkgs/userspace/orbterm.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs)
          orbterm-src
          orbclient-src
          orbfont-src
          orbimage-src
          libredox-src
          relibc-src
          ;
      };

      # Create initfs using modular mkInitfs factory function (headless)
      initfs = modularPkgs.infrastructure.mkInitfs {
        inherit (modularPkgs.system) base;
        inherit (modularPkgs.userspace) ion redoxfsTarget netutils;
        enableGraphics = false;
      };

      # Graphical initfs with display drivers
      initfsGraphical = modularPkgs.infrastructure.mkInitfs {
        inherit (modularPkgs.system) base;
        inherit (modularPkgs.userspace) ion redoxfsTarget netutils;
        enableGraphics = true;
      };

      # Create disk image using modular mkDiskImage factory function
      # Default: auto mode (DHCP with static fallback)
      diskImage = modularPkgs.infrastructure.mkDiskImage {
        inherit (modularPkgs.system) kernel bootloader base;
        inherit initfs sodium;
        inherit (modularPkgs.userspace)
          ion
          uutils
          helix
          binutils
          extrautils
          netutils
          ;
        redoxfs = modularPkgs.host.redoxfs;
        networkMode = "auto";
      };

      # Cloud Hypervisor optimized disk image with static networking
      # Skips DHCP, applies static config immediately for faster boot
      diskImageCloudHypervisor = modularPkgs.infrastructure.mkDiskImage {
        inherit (modularPkgs.system) kernel bootloader base;
        inherit initfs sodium;
        inherit (modularPkgs.userspace)
          ion
          uutils
          helix
          binutils
          extrautils
          netutils
          ;
        redoxfs = modularPkgs.host.redoxfs;
        networkMode = "static";
        staticNetworkConfig = {
          ip = "172.16.0.2";
          netmask = "255.255.255.0";
          gateway = "172.16.0.1";
        };
      };

      # Graphical disk image with Orbital desktop
      # Includes graphics drivers and orbdata (fonts, icons)
      # NOTE: orbital and orbterm packages are currently blocked due to
      # complex nested dependencies. The graphical initfs includes graphics
      # drivers (vesad, inputd, bgad, virtio-gpud) but no desktop will appear.
      diskImageGraphical = modularPkgs.infrastructure.mkDiskImage {
        inherit (modularPkgs.system) kernel bootloader base;
        initfs = initfsGraphical;
        inherit sodium orbdata;
        inherit (modularPkgs.userspace)
          ion
          uutils
          helix
          binutils
          extrautils
          netutils
          ;
        redoxfs = modularPkgs.host.redoxfs;
        networkMode = "auto";
        enableGraphics = true;
        # orbital and orbterm are blocked - not passed
        # When resolved, add:
        # orbital = orbital;
        # orbterm = orbterm;
      };

      # QEMU runners from modular infrastructure
      qemuRunners = modularPkgs.infrastructure.mkQemuRunners {
        inherit diskImage;
        inherit (modularPkgs.system) bootloader;
      };

      # Graphical QEMU runners using diskImageGraphical
      # Note: Without orbital/orbterm, this shows graphics drivers initializing
      # but no desktop appears. Useful for testing graphics driver boot.
      qemuRunnersGraphical = modularPkgs.infrastructure.mkQemuRunners {
        diskImage = diskImageGraphical;
        inherit (modularPkgs.system) bootloader;
      };

      # Cloud Hypervisor runners from modular infrastructure
      # headless uses default diskImage (auto network mode)
      # withNetwork uses diskImageCloudHypervisor (static network mode for TAP)
      cloudHypervisorRunners = modularPkgs.infrastructure.mkCloudHypervisorRunners {
        inherit diskImage;
        diskImageNet = diskImageCloudHypervisor;
      };

      # Combined sysroot
      sysroot = pkgs.symlinkJoin {
        name = "redox-sysroot";
        paths = [
          rustToolchain
          modularPkgs.system.relibc
        ];
      };

    in
    {
      packages = {
        # Host tools
        inherit (modularPkgs.host) cookbook redoxfs installer;
        fstools = modularPkgs.host.fstools;

        # System components
        inherit (modularPkgs.system)
          relibc
          kernel
          bootloader
          base
          ;
        inherit sysroot sysrootVendor;

        # Userspace packages
        inherit (modularPkgs.userspace)
          ion
          helix
          binutils
          netutils
          uutils
          redoxfsTarget
          extrautils
          ;
        inherit sodium;

        # Orbital graphics packages
        inherit orbdata orbital orbterm;

        # Infrastructure
        inherit (modularPkgs.infrastructure) initfsTools bootstrap;
        inherit
          initfs
          initfsGraphical
          diskImage
          diskImageCloudHypervisor
          diskImageGraphical
          ;

        # QEMU runners
        runQemu = qemuRunners.headless;
        runQemuGraphical = qemuRunners.graphical;
        bootTest = qemuRunners.bootTest;

        # Graphical QEMU runners (uses diskImageGraphical with graphics drivers)
        # Note: orbital/orbterm are blocked, so no desktop appears yet
        runQemuGraphicalDrivers = qemuRunnersGraphical.graphical;
        runQemuGraphicalDriversHeadless = qemuRunnersGraphical.headless;

        # Cloud Hypervisor runners
        runCloudHypervisor = cloudHypervisorRunners.headless;
        runCloudHypervisorNet = cloudHypervisorRunners.withNetwork;
        setupCloudHypervisorNetwork = cloudHypervisorRunners.setupNetwork;

        # Default package
        default = modularPkgs.host.fstools;

        # Legacy image builders (for backwards compatibility)
        image-desktop = pkgs.runCommand "redox-desktop-image" { } ''
          mkdir -p $out
          echo "Use 'nix build .#diskImage' for a complete bootable image" > $out/README
        '';

        image-server = pkgs.runCommand "redox-server-image" { } ''
          mkdir -p $out
          echo "Use 'nix build .#diskImage' for a complete bootable image" > $out/README
        '';
      };

      # Expose configuration for other modules
      _module.args.redoxConfig = {
        inherit
          rustToolchain
          craneLib
          sysrootVendor
          redoxTarget
          redoxLib
          modularPkgs
          ;
      };
    };
}
