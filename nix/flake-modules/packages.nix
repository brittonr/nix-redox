# RedoxOS packages module (adios-flake)
#
# Exports all RedoxOS packages through the standard flake interface.
# Uses redox-env.nix for shared toolchain/config computation.
#
# Access via:
#   self.packages.${system}.cookbook
#   self.packages.${system}.relibc

{
  pkgs,
  system,
  lib,
  self,
  ...
}:
let
  inputs = self.inputs;

  # Shared build environment (config + toolchain + sources + modular packages)
  env = import ./redox-env.nix {
    inherit
      pkgs
      system
      lib
      inputs
      ;
  };

  inherit (env)
    rustToolchain
    craneLib
    sysrootVendor
    redoxTarget
    redoxLib
    modularPkgs
    ;

  # Common args for all standalone packages
  standaloneCommon = {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      ;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs vendor;
  };

  # === Standalone packages (special handling, not in modularPkgs) ===

  sodium = import ../pkgs/userspace/sodium.nix (
    standaloneCommon
    // {
      inherit (inputs) sodium-src orbclient-src;
    }
  );

  orbdata = import ../pkgs/userspace/orbdata.nix {
    inherit pkgs lib;
    inherit (inputs) orbdata-src;
  };

  orbital = import ../pkgs/userspace/orbital.nix (
    standaloneCommon
    // {
      inherit craneLib;
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
        base-orbital-compat-src
        ;
    }
  );

  orbterm = import ../pkgs/userspace/orbterm.nix (
    standaloneCommon
    // {
      inherit (inputs)
        orbterm-src
        orbclient-src
        orbfont-src
        orbimage-src
        libredox-src
        relibc-src
        ;
    }
  );

  orbutils = import ../pkgs/userspace/orbutils.nix (
    standaloneCommon
    // {
      inherit (inputs) orbutils-src;
    }
  );

  userutils = import ../pkgs/userspace/userutils.nix (
    standaloneCommon
    // {
      inherit craneLib;
      inherit (inputs)
        userutils-src
        termion-src
        orbclient-src
        libredox-src
        ;
    }
  );

  ripgrep = import ../pkgs/userspace/ripgrep.nix (
    standaloneCommon
    // {
      inherit (inputs) ripgrep-src;
    }
  );

  fd = import ../pkgs/userspace/fd.nix (
    standaloneCommon
    // {
      inherit (inputs) fd-src;
    }
  );

  bat = import ../pkgs/userspace/bat.nix (
    standaloneCommon
    // {
      inherit (inputs) bat-src;
    }
  );

  hexyl = import ../pkgs/userspace/hexyl.nix (
    standaloneCommon
    // {
      inherit (inputs) hexyl-src;
    }
  );

  zoxide = import ../pkgs/userspace/zoxide.nix (
    standaloneCommon
    // {
      inherit (inputs) zoxide-src;
    }
  );

  dust = import ../pkgs/userspace/dust.nix (
    standaloneCommon
    // {
      inherit (inputs) dust-src;
    }
  );

  snix = import ../pkgs/userspace/snix.nix (
    standaloneCommon
    // {
      snix-redox-src = ../../snix-redox;
    }
  );

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

    # User management
    inherit userutils;

    # CLI tools
    inherit
      ripgrep
      fd
      bat
      hexyl
      zoxide
      dust
      snix
      ;

    # Infrastructure (needed by module system)
    inherit (modularPkgs.infrastructure) initfsTools bootstrap;

    # Default package
    default = modularPkgs.host.fstools;
  };

  # Expose build environment for other modules via legacyPackages
  legacyPackages = {
    inherit rustToolchain craneLib;
  };
}
