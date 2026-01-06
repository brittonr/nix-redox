{
  description = ''
    RedoxOS - Pure Nix build system

    A complete, reproducible build system for RedoxOS using Nix flakes.
    Replaces the traditional Make/Podman workflow with pure Nix derivations.

    Quick start:
      nix build .#diskImage     - Build complete bootable image
      nix run .#run-redox       - Run in Cloud Hypervisor (default)
      nix run .#run-redox-graphical - Run in QEMU with display
      nix run .#run-redox-qemu  - Run in QEMU headless (legacy)
      nix develop               - Enter development shell

    Cloud Hypervisor is the default VMM for its lower overhead and Rust-based
    security. QEMU is used for graphical mode due to better input handling.

    Host tools: cookbook, redoxfs, installer
    System: relibc, kernel, bootloader, base
    Userspace: ion, helix, binutils, extrautils, uutils, sodium, netutils
    CLI tools: ripgrep (rg), fd, bat, hexyl, tokei, zoxide, dust, difft
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

    # redox-scheme for orbital/inputd (0.8.3 required)
    # NOTE: Currently blocked due to syscall 0.6.0 API incompatibility
    # See nix/pkgs/userspace/orbital.nix for details
    redox-scheme-src = {
      url = "gitlab:redox-os/redox-scheme/master?host=gitlab.redox-os.org";
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

    # base pinned to the commit that orbital's Cargo.lock references
    # This older version of graphics-ipc uses drm-sys 0.8.0 and is compatible with syscall 0.5
    base-orbital-compat-src = {
      url = "gitlab:redox-os/base/620b4bd80c4f437adcaeec570b6cbba0487506d3?host=gitlab.redox-os.org";
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

    # Note: inputd and graphics-ipc are subdirectories of base-src:
    # - base-src/drivers/inputd
    # - base-src/drivers/graphics/graphics-ipc

    # redox-log - logging library for Redox
    redox-log-src = {
      url = "gitlab:redox-os/redox-log/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # userutils - user management utilities (getty, login, passwd, su, sudo)
    userutils-src = {
      url = "gitlab:redox-os/userutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # redox_users - user/group management library
    redox-users-src = {
      url = "gitlab:redox-os/users/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # termion - terminal I/O library for Redox
    termion-src = {
      url = "gitlab:redox-os/termion/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # redox_liner - line editing library
    redox-liner-src = {
      url = "gitlab:redox-os/liner/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # ripgrep - fast regex search tool (upstream with Redox support via libc)
    ripgrep-src = {
      url = "github:BurntSushi/ripgrep/14.1.1";
      flake = false;
    };

    # fd - fast find alternative (upstream, has Redox support via libc)
    fd-src = {
      url = "github:sharkdp/fd/v10.2.0";
      flake = false;
    };

    # bat - cat(1) clone with syntax highlighting (upstream, available in Redox pkg repo)
    bat-src = {
      url = "github:sharkdp/bat/v0.24.0";
      flake = false;
    };

    # hexyl - command-line hex viewer (upstream, available in Redox pkg repo)
    hexyl-src = {
      url = "github:sharkdp/hexyl/v0.14.0";
      flake = false;
    };

    # tokei - code statistics tool (upstream, available in Redox pkg repo)
    tokei-src = {
      url = "github:XAMPPRocky/tokei/v12.1.2";
      flake = false;
    };

    # zoxide - smarter cd command (upstream, available in Redox pkg repo)
    zoxide-src = {
      url = "github:ajeetdsouza/zoxide/v0.9.4";
      flake = false;
    };

    # dust - intuitive disk usage analyzer (upstream)
    dust-src = {
      url = "github:bootandy/dust/v1.0.0";
      flake = false;
    };

    # difftastic - structural diff tool (upstream)
    difft-src = {
      url = "github:Wilfred/difftastic/0.59.0";
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
