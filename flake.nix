{
  description = ''
    RedoxOS - Pure Nix build system

    A complete, reproducible build system for RedoxOS using Nix flakes.
    Replaces the traditional Make/Podman workflow with pure Nix derivations.

    Quick start:
      nix build .#diskImage     - Build complete bootable image
      nix run .#run-redox       - Run in QEMU (headless)
      nix run .#run-redox-graphical - Run with display
      nix run .#run-redox-cloud-hypervisor - Run in Cloud Hypervisor
      nix develop               - Enter development shell

    Host tools: cookbook, redoxfs, installer
    System: relibc, kernel, bootloader, base
    Userspace: ion, helix, binutils, extrautils, uutils, sodium, netutils
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # Code formatting with treefmt
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pre-commit hooks
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    # Redox source repositories
    relibc-src = {
      url = "gitlab:redox-os/relibc/master?host=gitlab.redox-os.org";
      flake = false;
    };

    kernel-src = {
      url = "gitlab:redox-os/kernel/master?host=gitlab.redox-os.org";
      flake = false;
    };

    redoxfs-src = {
      url = "gitlab:redox-os/redoxfs/master?host=gitlab.redox-os.org";
      flake = false;
    };

    installer-src = {
      url = "gitlab:redox-os/installer/master?host=gitlab.redox-os.org";
      flake = false;
    };

    pkgutils-src = {
      url = "gitlab:redox-os/pkgutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    ion-src = {
      url = "gitlab:redox-os/ion/master?host=gitlab.redox-os.org";
      flake = false;
    };

    helix-src = {
      url = "gitlab:redox-os/helix/redox?host=gitlab.redox-os.org";
      flake = false;
    };

    # The main Redox repository (contains cookbook)
    redox-src = {
      url = "gitlab:redox-os/redox/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # relibc submodules
    openlibm-src = {
      url = "gitlab:redox-os/openlibm/master?host=gitlab.redox-os.org";
      flake = false;
    };

    compiler-builtins-src = {
      url = "gitlab:redox-os/compiler-builtins/relibc_fix_dup_symbols?host=gitlab.redox-os.org";
      flake = false;
    };

    dlmalloc-rs-src = {
      url = "gitlab:redox-os/dlmalloc-rs/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # relibc cargo patches
    cc-rs-src = {
      url = "github:tea/cc-rs/riscv-abi-arch-fix";
      flake = false;
    };

    redox-syscall-src = {
      url = "gitlab:redox-os/syscall/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # kernel git dependency (for aarch64/riscv64)
    fdt-src = {
      url = "github:repnop/fdt/2fb1409edd1877c714a0aa36b6a7c5351004be54";
      flake = false;
    };

    # relibc object dependency
    object-src = {
      url = "gitlab:andypython/object/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # kernel submodules
    rmm-src = {
      url = "gitlab:redox-os/rmm/master?host=gitlab.redox-os.org";
      flake = false;
    };

    redox-path-src = {
      url = "gitlab:redox-os/redox-path/main?host=gitlab.redox-os.org";
      flake = false;
    };

    # bootloader
    bootloader-src = {
      url = "gitlab:redox-os/bootloader/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # bootloader dependencies (redox uefi library)
    uefi-src = {
      url = "gitlab:redox-os/uefi/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # base - essential system components (init, drivers, daemons)
    base-src = {
      url = "gitlab:redox-os/base/main?host=gitlab.redox-os.org";
      flake = false;
    };

    # base git dependencies
    liblibc-src = {
      url = "gitlab:redox-os/liblibc/redox-0.2?host=gitlab.redox-os.org";
      flake = false;
    };

    orbclient-src = {
      url = "gitlab:redox-os/orbclient/master?host=gitlab.redox-os.org";
      flake = false;
    };

    rustix-redox-src = {
      url = "github:jackpot51/rustix/redox-ioctl";
      flake = false;
    };

    drm-rs-src = {
      url = "github:Smithay/drm-rs";
      flake = false;
    };

    # uutils coreutils - Rust implementation of GNU coreutils
    uutils-src = {
      url = "github:uutils/coreutils/0.0.27";
      flake = false;
    };

    # binutils - binary utilities (strings, hex, hexdump)
    binutils-src = {
      url = "gitlab:redox-os/binutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # extrautils - extended utilities (grep, tar, gzip, less, etc.)
    extrautils-src = {
      url = "gitlab:redox-os/extrautils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # sodium - vi-like text editor
    sodium-src = {
      url = "gitlab:redox-os/sodium/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # extrautils dependencies
    filetime-src = {
      url = "github:jackpot51/filetime";
      flake = false;
    };

    # libredox - stable API for Redox OS
    libredox-src = {
      url = "gitlab:redox-os/libredox/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # netutils - network utilities (dhcpd, dnsd, ping, ifconfig, nc)
    netutils-src = {
      url = "gitlab:redox-os/netutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # Orbital ecosystem - graphical desktop support
    orbital-src = {
      url = "gitlab:redox-os/orbital/master?host=gitlab.redox-os.org";
      flake = false;
    };

    orbdata-src = {
      url = "gitlab:redox-os/orbdata/master?host=gitlab.redox-os.org";
      flake = false;
    };

    orbterm-src = {
      url = "gitlab:redox-os/orbterm/master?host=gitlab.redox-os.org";
      flake = false;
    };

    orbutils-src = {
      url = "gitlab:redox-os/orbutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # orbfont - font rendering for Orbital
    orbfont-src = {
      url = "gitlab:redox-os/orbfont/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # orbimage - image loading for Orbital
    orbimage-src = {
      url = "gitlab:redox-os/orbimage/master?host=gitlab.redox-os.org";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      rust-overlay,
      crane,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Import all flake-parts modules
      imports = [
        ./nix/flake-modules/toolchain.nix
        ./nix/flake-modules/sources.nix
        ./nix/flake-modules/packages.nix
        ./nix/flake-modules/devshells.nix
        ./nix/flake-modules/checks.nix
        ./nix/flake-modules/apps.nix
        ./nix/flake-modules/treefmt.nix
        ./nix/flake-modules/git-hooks.nix
        ./nix/flake-modules/overlays.nix
        ./nix/flake-modules/nixos-module.nix
        ./nix/flake-modules/flake-modules.nix
        ./nix/flake-modules/config.nix
      ];

      # Legacy packages interface (for backwards compatibility)
      perSystem =
        {
          pkgs,
          config,
          ...
        }:
        {
          legacyPackages = {
            inherit (config._module.args.redoxConfig or { }) rustToolchain craneLib;
          };
        };
    };
}
