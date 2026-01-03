# Flake-parts module for RedoxOS development shells
#
# This module provides various development environments:
# - default: Pure Nix development (recommended)
# - native: Full native environment with all tools
# - minimal: Minimal environment for quick iteration
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/devshells.nix ];

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      lib,
      config,
      self',
      ...
    }:
    let
      # Get toolchain from packages module
      redoxConfig = config._module.args.redoxConfig or null;

      rustToolchain =
        if redoxConfig != null then
          redoxConfig.rustToolchain
        else
          # Fallback: build toolchain here
          let
            pkgsWithOverlay = import inputs.nixpkgs {
              inherit (pkgs) system;
              overlays = [ inputs.rust-overlay.overlays.default ];
            };
          in
          pkgsWithOverlay.rust-bin.nightly."2025-10-03".default.override {
            extensions = [
              "rust-src"
              "rustfmt"
              "clippy"
              "rust-analyzer"
            ];
            targets = [ "x86_64-unknown-redox" ];
          };

      redoxTarget = "x86_64-unknown-redox";

      # Common native build inputs
      commonNativeBuildInputs = with pkgs; [
        rustToolchain
        pkg-config
        gnumake
        cmake
        ninja
        nasm
        gcc
        clang
        llvmPackages.llvm
        automake
        autoconf
        libtool
        bison
        flex
        m4
        just
        rust-cbindgen
      ];

      # Common build inputs (libraries)
      commonBuildInputs = with pkgs; [
        fuse
        fuse3
        openssl
        zlib
        expat
      ];

      # PKG_CONFIG_PATH for library discovery
      pkgConfigPath = lib.makeSearchPath "lib/pkgconfig" (
        with pkgs;
        [
          openssl.dev
          fuse.dev
          fuse3.dev
          expat
          zlib
        ]
      );

      # Common Rust environment for cross-compilation
      rustEnv = {
        CARGO_BUILD_TARGET = redoxTarget;
        RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
        TARGET = redoxTarget;
      };

    in
    {
      devShells = {
        # Default: Pure Nix development (no containers)
        default = pkgs.mkShell {
          name = "redox-nix";

          nativeBuildInputs = commonNativeBuildInputs ++ [
            self'.packages.fstools
            pkgs.qemu_kvm
            pkgs.git
            pkgs.curl
            pkgs.wget
          ];

          buildInputs = commonBuildInputs;

          inherit (rustEnv) CARGO_BUILD_TARGET RUST_SRC_PATH TARGET;
          PKG_CONFIG_PATH = pkgConfigPath;
          NIX_SHELL_BUILD = "1";
          PODMAN_BUILD = "0";

          # Point to Nix-built tools
          COOKBOOK_BIN = "${self'.packages.cookbook}/bin/repo";
          REDOXFS_BIN = "${self'.packages.redoxfs}/bin/redoxfs";
          INSTALLER_BIN = "${self'.packages.installer}/bin/redox_installer";

          shellHook = ''
            echo "RedoxOS Nix Development Environment"
            echo ""
            echo "Rust: $(rustc --version)"
            echo "Target: ${redoxTarget}"
            echo ""
            echo "Pure Nix builds (no network required):"
            echo "  nix build .#cookbook   - Package manager (repo command)"
            echo "  nix build .#redoxfs    - RedoxFS filesystem tools"
            echo "  nix build .#fstools    - All host tools combined"
            echo "  nix run .#run-redox    - Run Redox image in QEMU"
            echo ""
            echo "Cross-compiled components:"
            echo "  nix build .#relibc"
            echo "  nix build .#kernel"
            echo "  nix build .#diskImage  - Complete bootable disk image"
            echo ""
          '';
        };

        # Native build with all tools (backwards compatible)
        native = pkgs.mkShell {
          name = "redox-native";

          nativeBuildInputs =
            commonNativeBuildInputs
            ++ (with pkgs; [
              git
              git-lfs
              rsync
              python3
              python3Packages.mako
              perl
              lua
              doxygen
              help2man
              texinfo
              curl
              wget
              cacert
              zip
              unzip
              patch
              patchelf
              file
              gperf
              ant
              xdg-utils
              gdb
              cdrkit
              zstd
              lzip
              xxd
              dos2unix
              qemu_kvm
              nix-ld
            ])
            ++ lib.optionals pkgs.stdenv.hostPlatform.isx86 [
              pkgs.syslinux
            ];

          buildInputs =
            commonBuildInputs
            ++ (with pkgs; [
              libpng
              libjpeg
              SDL2
              SDL2_ttf
              fontconfig
              freetype
              protobuf
              gmp
            ]);

          PKG_CONFIG_PATH = pkgConfigPath;
          FUSE_LIBRARY_PATH = "${pkgs.fuse}/lib";
          inherit (rustEnv) RUST_SRC_PATH TARGET;

          NIX_LD_LIBRARY_PATH = lib.makeLibraryPath (
            with pkgs;
            [
              stdenv.cc.cc
              glibc
              zlib
              openssl
              fuse
            ]
          );
          NIX_LD = "${pkgs.stdenv.cc}/nix-support/dynamic-linker";

          NIX_SHELL_BUILD = "1";
          PODMAN_BUILD = "0";

          shellHook = ''
            export LD_LIBRARY_PATH="$NIX_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
            echo "RedoxOS Native Build Environment"
            echo ""
            echo "Rust: $(rustc --version)"
            echo "Target: ${redoxTarget}"
            echo ""
            echo "Quick start: cd redox-src && make all PODMAN_BUILD=0"
          '';
        };

        # Minimal shell for quick iteration
        minimal = pkgs.mkShell {
          name = "redox-minimal";

          nativeBuildInputs = with pkgs; [
            rustToolchain
            gnumake
            just
            rust-cbindgen
            nasm
            pkg-config
            qemu_kvm
            fuse
          ];

          inherit (rustEnv) RUST_SRC_PATH TARGET;
          PKG_CONFIG_PATH = pkgConfigPath;
          NIX_SHELL_BUILD = "1";
          PODMAN_BUILD = "0";

          shellHook = ''
            echo "RedoxOS Minimal Environment"
          '';
        };
      };
    };
}
