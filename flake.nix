{
  description = ''
    Redox OS built entirely from source with Nix.

    nix run   — Boot a graphical Redox desktop (QEMU + GTK)
    nix build — Build the disk image
  '';

  nixConfig = {
    extra-substituters = [ "https://nix-redox.cachix.org" ];
    extra-trusted-public-keys = [
      "nix-redox.cachix.org-1:d0dvP2sgt2k2M3MRT6lHm4S0AMAtOP6yiuvSDF8Khuc="
    ];
  };

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

    # Use Git instead of GitLab's archive API, which denies hosted CI runners.
    # Revisions and NAR identities remain pinned in flake.lock.
    relibc-src = {
      # Full history: the locked revision is no longer on the master tip, and a
      # shallow fetch cannot find it in the branch history.
      url = "git+https://gitlab.redox-os.org/redox-os/relibc.git?ref=master";
      flake = false;
    };

    kernel-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/kernel.git?ref=master&shallow=1";
      flake = false;
    };

    redoxfs-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redoxfs.git?ref=master&shallow=1";
      flake = false;
    };

    installer-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/installer.git?ref=master&shallow=1";
      flake = false;
    };

    pkgutils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/pkgutils.git?ref=master&shallow=1";
      flake = false;
    };

    ion-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/ion.git?ref=master&shallow=1";
      flake = false;
    };

    helix-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/helix.git?ref=redox&shallow=1";
      flake = false;
    };

    # The main Redox repository (contains cookbook)
    redox-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redox.git?ref=master&shallow=1";
      flake = false;
    };

    # relibc submodules
    openlibm-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/openlibm.git?ref=master&shallow=1";
      flake = false;
    };

    dlmalloc-rs-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/dlmalloc-rs.git?ref=main&shallow=1";
      flake = false;
    };

    # redox-scheme for orbital/inputd (0.8.3 required)
    # NOTE: Currently blocked due to syscall 0.6.0 API incompatibility
    # See nix/pkgs/userspace/orbital.nix for details
    redox-scheme-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-scheme.git?ref=master&shallow=1";
      flake = false;
    };

    # Bootloader/base device-tree dependency.
    fdt-src = {
      url = "github:repnop/fdt/2fb1409edd1877c714a0aa36b6a7c5351004be54";
      flake = false;
    };

    # The current kernel requires the newer fdt pretty-printing API.
    kernel-fdt-src = {
      url = "github:repnop/fdt/8fa4388e056e48826e8898557a1c8600f9ee5d6a";
      flake = false;
    };

    redox-path-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-path.git?ref=main&shallow=1";
      flake = false;
    };

    # bootloader
    bootloader-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/bootloader.git?ref=master&shallow=1";
      flake = false;
    };

    # bootloader dependencies (redox uefi library)
    uefi-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/uefi.git?ref=master&shallow=1";
      flake = false;
    };

    # base - essential system components (init, drivers, daemons)
    base-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/base.git?ref=main&shallow=1";
      flake = false;
    };

    # Keep graphics-ipc/inputd at the exact base revision in Orbital's Cargo.lock.
    base-orbital-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/base.git?rev=c4f68cdce365713a9557c84a98642226ae62b073&shallow=1";
      flake = false;
    };

    orbclient-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbclient.git?ref=master&shallow=1";
      flake = false;
    };

    rustix-redox-src = {
      url = "github:jackpot51/rustix/redox-ioctl";
      flake = false;
    };

    # uutils coreutils - Rust implementation of GNU coreutils
    uutils-src = {
      url = "github:uutils/coreutils/0.0.27";
      flake = false;
    };

    # binutils - binary utilities (strings, hex, hexdump)
    binutils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/binutils.git?ref=master&shallow=1";
      flake = false;
    };

    # extrautils - extended utilities (grep, tar, gzip, less, etc.)
    extrautils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/extrautils.git?ref=master&shallow=1";
      flake = false;
    };

    # sodium - vi-like text editor
    sodium-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/sodium.git?ref=master&shallow=1";
      flake = false;
    };

    # extrautils dependencies
    filetime-src = {
      url = "github:jackpot51/filetime";
      flake = false;
    };

    # libredox - stable API for Redox OS
    libredox-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/libredox.git?ref=master&shallow=1";
      flake = false;
    };

    # netutils - network utilities (dhcpd, dnsd, ping, ifconfig, nc)
    netutils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/netutils.git?ref=master&shallow=1";
      flake = false;
    };

    # Orbital ecosystem - graphical desktop support
    orbital-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbital.git?ref=master&shallow=1";
      flake = false;
    };

    orbdata-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbdata.git?ref=master&shallow=1";
      flake = false;
    };

    orbterm-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbterm.git?ref=master&shallow=1";
      flake = false;
    };

    orbutils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbutils.git?ref=master&shallow=1";
      flake = false;
    };

    # orbfont - font rendering for Orbital
    orbfont-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbfont.git?ref=master&shallow=1";
      flake = false;
    };

    # orbimage - image loading for Orbital
    orbimage-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/orbimage.git?ref=master&shallow=1";
      flake = false;
    };

    # Note: inputd and graphics-ipc are subdirectories of base-src:
    # - base-src/drivers/inputd
    # - base-src/drivers/graphics/graphics-ipc

    # redox-log - logging library for Redox
    redox-log-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-log.git?ref=master&shallow=1";
      flake = false;
    };

    # userutils - user management utilities (getty, login, passwd, su, sudo)
    userutils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/userutils.git?ref=master&shallow=1";
      flake = false;
    };

    # termion - terminal I/O library for Redox
    termion-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/termion.git?ref=master&shallow=1";
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
      url = "git+https://gitlab.redox-os.org/redox-os/Smith.git?ref=master&shallow=1";
      flake = false;
    };

    # strace-redox - system call tracer (Redox-native)
    strace-redox-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/strace-redox.git?ref=master&shallow=1";
      flake = false;
    };

    # findutils - find command (Redox-native)
    findutils-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/findutils.git?ref=master&shallow=1";
      flake = false;
    };

    # contain - container/namespace tool (Redox-native)
    contain-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/contain.git?ref=master&shallow=1";
      flake = false;
    };

    # pkgar - package archive tool (Redox-native)
    pkgar-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/pkgar.git?ref=master&shallow=1";
      flake = false;
    };

    # exampled - example scheme daemon (Redox-native)
    exampled-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/exampled.git?ref=master&shallow=1";
      flake = false;
    };

    # games - terminal games collection (Redox-native)
    games-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/games.git?ref=master&shallow=1";
      flake = false;
    };

    # openssl - Redox-patched OpenSSL fork (v1 branch)
    openssl-redox-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/openssl.git?ref=redox-v1&shallow=1";
      flake = false;
    };

    # openssl3 - upstream OpenSSL 3.x release tarball
    openssl3-src = {
      url = "https://github.com/openssl/openssl/releases/download/openssl-3.5.3/openssl-3.5.3.tar.gz";
      flake = false;
    };

    # openssh - upstream OpenSSH portable release tarball
    openssh-src = {
      url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.8p1.tar.gz";
      flake = false;
    };

    # ca-certificates - TLS root certificate bundle
    ca-certificates-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/ca-certificates.git?ref=master&shallow=1";
      flake = false;
    };

    # terminfo - terminal capability database
    terminfo-src = {
      url = "github:sajattack/terminfo";
      flake = false;
    };

    # netdb - network database (hosts, services, protocols)
    netdb-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/netdb.git?ref=master&shallow=1";
      flake = false;
    };

    # wasmtime - WebAssembly runtime cross-compiled for Redox
    wasmtime-redox = {
      url = "github:brittonr/wasmtime-redox/dfa064f8889900effdc54b9a257cedfee4fcc399";
    };

    # bottom - graphical system monitor (upstream release)
    bottom-src = {
      url = "github:ClementTsang/bottom/0.11.2";
      flake = false;
    };

    # onefetch - git repository summary (upstream, cargo template)
    onefetch-src = {
      url = "github:o2sh/onefetch/v2.13.2";
      flake = false;
    };

    # gdb-protocol - GDB Remote Serial Protocol implementation
    gdb-protocol-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/gdb-protocol.git?ref=master&shallow=1";
      flake = false;
    };

    # intelflash - Intel SPI flash read/write library
    intelflash-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/intelflash.git?ref=master&shallow=1";
      flake = false;
    };

    # redox-buffer-pool - zero-copy shared buffer management for drivers
    buffer-pool-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-buffer-pool.git?ref=master&shallow=1";
      flake = false;
    };

    # kprofiling - kernel profiling data converter
    kprofiling-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/kprofiling.git?ref=master&shallow=1";
      flake = false;
    };

    # redoxer - run Redox programs from Linux via KVM
    redoxer-src = {
      url = "git+https://gitlab.redox-os.org/redox-os/redoxer.git?ref=master&shallow=1";
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
        (import ./nix/flake-modules/browser.nix)
        (import ./nix/flake-modules/apps.nix)
        (import ./nix/flake-modules/devshells.nix)
        (import ./nix/flake-modules/checks.nix)
        (import ./nix/flake-modules/treefmt.nix)
      ];

      # System-agnostic outputs
      flake =
        { withSystem }:
        let
          nixpkgsLib = inputs.nixpkgs.lib;
          redoxSystemFactory = import ./nix/redox-system { lib = nixpkgsLib; };
        in
        {
          # Primary API — build a Redox system from modules
          # Usage: redox.lib.redoxSystem { modules = [ ./config.nix ]; pkgs = ...; hostPkgs = ...; }
          lib = {
            inherit (redoxSystemFactory) redoxSystem;
          };

          # Named system configurations (like darwinConfigurations / nixosConfigurations)
          redoxConfigurations = withSystem "x86_64-linux" (
            { self', pkgs, ... }:
            let
              mkSys = modules: self'.legacyPackages.mkRedoxSystem { inherit modules; };
            in
            {
              default = mkSys [ ./nix/redox-system/profiles/development.nix ];
              minimal = mkSys [ ./nix/redox-system/profiles/minimal.nix ];
              graphical = mkSys [ ./nix/redox-system/profiles/graphical.nix ];
              cloud = mkSys [ ./nix/redox-system/profiles/cloud-hypervisor.nix ];
              self-hosting = mkSys [ ./nix/redox-system/profiles/self-hosting.nix ];
              browser-demo = self'.legacyPackages.browserSystem;
              browser-graphical = self'.legacyPackages.graphicalSystem;
            }
          );

          # Flake module for downstream flake-parts / adios-flake consumers
          flakeModules.default = ./nix/flake-module.nix;

          # Template: nix flake init -t github:brittonr/nix-redox
          templates.default = {
            path = ./templates/default;
            description = "Minimal Redox OS system configuration";
          };

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
