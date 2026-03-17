{
  description = ''
    Redox OS built entirely from source with Nix.

    nix run   — Boot a graphical Redox desktop (QEMU + GTK)
    nix build — Build the disk image
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    adios-flake.url = "github:Mic92/adios-flake";

    # Kept as a top-level input so upstream dependencies that use
    # flake-parts all share a single copy via follows.
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

    # Per-crate Nix builds for host-side testing of snix-redox
    unit2nix = {
      url = "github:brittonr/unit2nix";
      inputs.nixpkgs.follows = "nixpkgs";
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
      url = "gitlab:redox-os/dlmalloc-rs/main?host=gitlab.redox-os.org";
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

    # tokei - count lines of code (upstream)
    tokei-src = {
      url = "github:XAMPPRocky/tokei/v14.0.0";
      flake = false;
    };

    # lsd - modern ls replacement (upstream)
    lsd-src = {
      url = "github:lsd-rs/lsd/v1.2.0";
      flake = false;
    };

    # shellharden - shell script linter (upstream, pinned rev for Redox compat)
    shellharden-src = {
      url = "github:anordal/shellharden/v4.3.1";
      flake = false;
    };

    # perg - parallel grep (upstream, pinned rev for Redox compat)
    perg-src = {
      url = "github:guerinoni/perg/0.6.0";
      flake = false;
    };

    # smith - text editor (Redox-native)
    smith-src = {
      url = "gitlab:redox-os/Smith/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # strace-redox - system call tracer (Redox-native)
    strace-redox-src = {
      url = "gitlab:redox-os/strace-redox/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # findutils - find command (Redox-native)
    findutils-src = {
      url = "gitlab:redox-os/findutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # contain - container/namespace tool (Redox-native)
    contain-src = {
      url = "gitlab:redox-os/contain/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # pkgar - package archive tool (Redox-native)
    pkgar-src = {
      url = "gitlab:redox-os/pkgar/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # redox-ssh - SSH client/server (Redox-native)
    redox-ssh-src = {
      url = "gitlab:redox-os/redox-ssh/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # exampled - example scheme daemon (Redox-native)
    exampled-src = {
      url = "gitlab:redox-os/exampled/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # games - terminal games collection (Redox-native)
    games-src = {
      url = "gitlab:redox-os/games/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # openssl - Redox-patched OpenSSL fork (v1 branch)
    openssl-redox-src = {
      url = "gitlab:redox-os/openssl/redox-v1?host=gitlab.redox-os.org";
      flake = false;
    };

    # ca-certificates - TLS root certificate bundle
    ca-certificates-src = {
      url = "gitlab:redox-os/ca-certificates/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # terminfo - terminal capability database
    terminfo-src = {
      url = "github:sajattack/terminfo";
      flake = false;
    };

    # netdb - network database (hosts, services, protocols)
    netdb-src = {
      url = "gitlab:redox-os/netdb/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # bottom - graphical system monitor (Redox fork)
    bottom-src = {
      url = "github:jackpot51/bottom";
      flake = false;
    };

    # onefetch - git repository summary (upstream, cargo template)
    onefetch-src = {
      url = "github:o2sh/onefetch/v2.13.2";
      flake = false;
    };
  };

  outputs =
    inputs@{ adios-flake, self, ... }:
    adios-flake.lib.mkFlake {
      inherit inputs self;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Per-system modules (each is a plain function)
      modules = [
        (import ./nix/flake-modules/packages.nix)
        (import ./nix/flake-modules/system.nix)
        (import ./nix/flake-modules/apps.nix)
        (import ./nix/flake-modules/devshells.nix)
        (import ./nix/flake-modules/checks.nix)
        (import ./nix/flake-modules/treefmt.nix)
      ];

      # System-agnostic outputs
      flake =
        { withSystem }:
        {
          # NixOS modules for host integration
          nixosModules = import ./nix/nixos-modules { inherit self; };

          # Overlay for other flakes to consume RedoxOS packages
          overlays.default =
            final: _prev:
            let
              perSys = withSystem final.system ({ self', ... }: self'.packages);
            in
            {
              redox = {
                # Host tools
                inherit (perSys)
                  cookbook
                  redoxfs
                  installer
                  fstools
                  ;
                # System components
                inherit (perSys)
                  relibc
                  kernel
                  bootloader
                  base
                  sysroot
                  ;
                # Userspace
                inherit (perSys)
                  ion
                  helix
                  binutils
                  extrautils
                  sodium
                  netutils
                  uutils
                  redoxfsTarget
                  ;
                # Disk images
                inherit (perSys)
                  redox-default
                  redox-minimal
                  redox-graphical
                  redox-cloud
                  ;
                # Runners
                inherit (perSys)
                  run-redox-default
                  run-redox-default-qemu
                  run-redox-graphical-desktop
                  ;
              };
            };
        };
    };
}
