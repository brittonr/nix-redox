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
          redox-scheme-src
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
          redox-log-src
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
          # Userutils - user management (getty, login, passwd, su, sudo)
          userutils-src
          termion-src
          # CLI tools
          ripgrep-src
          fd-src
          # New developer tools
          bat-src
          hexyl-src
          zoxide-src
          dust-src
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

      # Import orbital (display server)
      orbital = import ../pkgs/userspace/orbital.nix {
        inherit
          pkgs
          lib
          craneLib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs)
          orbital-src
          orbclient-src
          orbfont-src
          orbimage-src
          libredox-src
          relibc-src
          liblibc-src
          rustix-redox-src
          drm-rs-src
          redox-log-src
          redox-syscall-src
          redox-scheme-src
          # Use orbital-compatible base commit (620b4bd) for graphics-ipc/inputd
          # This version uses drm-sys 0.8.0 and is compatible with syscall 0.5
          base-orbital-compat-src
          ;
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

      # Import orbutils (graphical utilities: orblogin, background)
      orbutils = import ../pkgs/userspace/orbutils.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) orbutils-src;
      };

      # Import userutils (getty, login, passwd, su, sudo)
      userutils = import ../pkgs/userspace/userutils.nix {
        inherit
          pkgs
          lib
          craneLib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs)
          userutils-src
          termion-src
          orbclient-src
          libredox-src
          ;
      };

      # Import ripgrep (fast regex search tool)
      ripgrep = import ../pkgs/userspace/ripgrep.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) ripgrep-src;
      };

      # Import fd (fast find alternative)
      fd = import ../pkgs/userspace/fd.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) fd-src;
      };

      # Import bat (cat clone with syntax highlighting)
      bat = import ../pkgs/userspace/bat.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) bat-src;
      };

      # Import hexyl (hex viewer)
      hexyl = import ../pkgs/userspace/hexyl.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) hexyl-src;
      };

      # Import zoxide (smart cd)
      zoxide = import ../pkgs/userspace/zoxide.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) zoxide-src;
      };

      # Import dust (disk usage analyzer)
      dust = import ../pkgs/userspace/dust.nix {
        inherit
          pkgs
          lib
          rustToolchain
          sysrootVendor
          redoxTarget
          ;
        inherit (modularPkgs.system) relibc;
        inherit (redoxLib) stubLibs vendor;
        inherit (inputs) dust-src;
      };

      # Create initfs using modular mkInitfs factory function (headless)
      initfs = modularPkgs.infrastructure.mkInitfs {
        inherit (modularPkgs.system) base;
        inherit (modularPkgs.userspace) ion redoxfsTarget netutils;
        inherit userutils;
        enableGraphics = false;
      };

      # Graphical initfs with display and audio drivers
      initfsGraphical = modularPkgs.infrastructure.mkInitfs {
        inherit (modularPkgs.system) base;
        inherit (modularPkgs.userspace) ion redoxfsTarget netutils;
        inherit userutils;
        enableGraphics = true;
        enableAudio = true;
      };

      # Create disk image using modular mkDiskImage factory function
      # Default: auto mode (DHCP with static fallback)
      diskImage = modularPkgs.infrastructure.mkDiskImage {
        inherit (modularPkgs.system) kernel bootloader base;
        inherit initfs sodium userutils;
        inherit (modularPkgs.userspace)
          ion
          uutils
          helix
          binutils
          extrautils
          netutils
          ;
        # Include new developer tools
        inherit
          bat
          hexyl
          zoxide
          dust
          ;
        redoxfs = modularPkgs.host.redoxfs;
        networkMode = "auto";
      };

      # Cloud Hypervisor optimized disk image with static networking
      # Skips DHCP, applies static config immediately for faster boot
      diskImageCloudHypervisor = modularPkgs.infrastructure.mkDiskImage {
        inherit (modularPkgs.system) kernel bootloader base;
        inherit initfs sodium userutils;
        inherit (modularPkgs.userspace)
          ion
          uutils
          helix
          binutils
          extrautils
          netutils
          ;
        # Include new developer tools
        inherit
          bat
          hexyl
          zoxide
          dust
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
      # Includes graphics drivers, orbdata (fonts, icons), orbital, and orbterm
      diskImageGraphical = modularPkgs.infrastructure.mkDiskImage {
        inherit (modularPkgs.system) kernel bootloader base;
        initfs = initfsGraphical;
        inherit
          sodium
          orbdata
          userutils
          orbital
          orbterm
          orbutils
          ;
        inherit (modularPkgs.userspace)
          ion
          uutils
          helix
          binutils
          extrautils
          netutils
          ;
        # Include new developer tools
        inherit
          bat
          hexyl
          zoxide
          dust
          ;
        redoxfs = modularPkgs.host.redoxfs;
        networkMode = "auto";
        enableGraphics = true;
        enableAudio = true;
      };

      # QEMU runners from modular infrastructure
      qemuRunners = modularPkgs.infrastructure.mkQemuRunners {
        inherit diskImage;
        inherit (modularPkgs.system) bootloader;
      };

      # Graphical QEMU runners using diskImageGraphical
      # Includes Orbital desktop environment and orbterm terminal emulator
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
        inherit
          orbdata
          orbital
          orbterm
          orbutils
          ;

        # Userutils - user management (getty, login, passwd, su, sudo)
        inherit userutils;

        # CLI tools
        inherit ripgrep fd;

        # New developer tools
        inherit
          bat
          hexyl
          zoxide
          dust
          ;

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
        runQemuGraphical = qemuRunnersGraphical.graphical;
        bootTest = qemuRunners.bootTest;

        # Headless runner with graphical disk image (for testing graphics drivers without display)
        runQemuGraphicalHeadless = qemuRunnersGraphical.headless;

        # Cloud Hypervisor runners
        runCloudHypervisor = cloudHypervisorRunners.headless;
        runCloudHypervisorNet = cloudHypervisorRunners.withNetwork;
        runCloudHypervisorDev = cloudHypervisorRunners.withDev;
        setupCloudHypervisorNetwork = cloudHypervisorRunners.setupNetwork;

        # Cloud Hypervisor ch-remote wrapper scripts
        pauseRedox = cloudHypervisorRunners.pauseVm;
        resumeRedox = cloudHypervisorRunners.resumeVm;
        snapshotRedox = cloudHypervisorRunners.snapshotVm;
        infoRedox = cloudHypervisorRunners.infoVm;
        resizeMemoryRedox = cloudHypervisorRunners.resizeMemory;

        # Default package
        default = modularPkgs.host.fstools;
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
