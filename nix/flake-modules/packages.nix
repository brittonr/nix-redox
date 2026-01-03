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
      ...
    }:
    let
      # Import nixpkgs with rust-overlay
      pkgsWithOverlay = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
      };

      # Configuration - can be overridden via module options
      config = {
        # Rust nightly version to use (matches rust-toolchain.toml)
        rustNightlyDate = "2025-10-03";
        # Primary target triple
        targetArch = "x86_64";
      };

      redoxTarget = "${config.targetArch}-unknown-redox";

      # Nightly Rust toolchain with Redox target
      rustToolchain = pkgsWithOverlay.rust-bin.nightly.${config.rustNightlyDate}.default.override {
        extensions = [
          "rust-src"
          "rustfmt"
          "clippy"
          "rust-analyzer"
        ];
        targets = [ redoxTarget ];
      };

      # Crane for building Rust packages
      craneLib = (inputs.crane.mkLib pkgsWithOverlay).overrideToolchain rustToolchain;

      # Import modular library for cross-compilation utilities
      redoxLib = import ../lib {
        inherit pkgs lib rustToolchain;
        inherit redoxTarget;
      };

      # Sysroot vendor from modular library (for -Z build-std)
      sysrootVendor = redoxLib.sysroot.vendor;

      # Source inputs for modular packages
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
          base-src
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
          ;
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
        inherit (redoxLib) stubLibs;
        inherit (inputs) sodium-src orbclient-src;
      };

      # Create initfs using modular mkInitfs factory function
      initfs = modularPkgs.infrastructure.mkInitfs {
        inherit (modularPkgs.system) base;
        inherit (modularPkgs.userspace) ion redoxfsTarget netutils;
      };

      # Create disk image using modular mkDiskImage factory function
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
      };

      # QEMU runners from modular infrastructure
      qemuRunners = modularPkgs.infrastructure.mkQemuRunners {
        inherit diskImage;
        inherit (modularPkgs.system) bootloader;
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

        # Infrastructure
        inherit (modularPkgs.infrastructure) initfsTools bootstrap;
        inherit initfs diskImage;

        # QEMU runners
        runQemu = qemuRunners.headless;
        runQemuGraphical = qemuRunners.graphical;
        bootTest = qemuRunners.bootTest;

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
