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
#   self.packages.${system}.relibc

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
          netcfg-setup
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

        # Infrastructure (needed by module system)
        inherit (modularPkgs.infrastructure) initfsTools bootstrap;

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
