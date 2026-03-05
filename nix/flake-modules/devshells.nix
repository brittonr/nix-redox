# RedoxOS development shells module (adios-flake)
#
# Provides development environments:
# - default: Pure Nix development (recommended)
# - native: Full native environment with all tools
# - minimal: Minimal environment for quick iteration
#
# Usage:
#   nix develop          # Default shell
#   nix develop .#native # Full environment
#   nix develop .#minimal

{
  pkgs,
  system,
  lib,
  self,
  self',
  ...
}:
let
  inputs = self.inputs;

  # Shared build environment
  env = import ./redox-env.nix {
    inherit
      pkgs
      system
      lib
      inputs
      ;
  };
  inherit (env) rustToolchain redoxTarget;

  # Git hooks via git-hooks.nix (direct lib usage, no flake-parts module)
  gitHooksEval = inputs.git-hooks.lib.${system}.run {
    src = self;
    hooks = {
      nixfmt-rfc-style = {
        enable = true;
        package = pkgs.nixfmt-rfc-style;
      };

      check-merge-conflicts.enable = true;

      check-added-large-files = {
        enable = true;
        stages = [ "pre-commit" ];
      };

      trim-trailing-whitespace = {
        enable = true;
        stages = [ "pre-commit" ];
      };

      end-of-file-fixer = {
        enable = true;
        stages = [ "pre-commit" ];
      };

      check-toml.enable = true;
      check-json.enable = true;
    };

    excludes = [
      "^vendor/"
      "^vendor-combined/"
      "^result.*/"
      # nixfmt breaks bash heredoc terminators inside Nix strings
      "^nix/redox-system/profiles/self-hosting-test\\.nix$"
    ];
  };
  gitHooksShellHook = gitHooksEval.shellHook;

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

  commonBuildInputs = with pkgs; [
    fuse
    fuse3
    openssl
    zlib
    expat
  ];

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

  rustEnv = {
    CARGO_BUILD_TARGET = redoxTarget;
    RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
    TARGET = redoxTarget;
    # Cross-only crates (redox, netcfg-setup) set [[bin]] test=false since
    # they can't link on the host. This tells nextest to pass with 0 tests
    # instead of failing.
    NEXTEST_NO_TESTS = "pass";
  };

in
{
  devShells = {
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

      inherit (rustEnv)
        CARGO_BUILD_TARGET
        RUST_SRC_PATH
        TARGET
        NEXTEST_NO_TESTS
        ;
      PKG_CONFIG_PATH = pkgConfigPath;
      NIX_SHELL_BUILD = "1";
      PODMAN_BUILD = "0";

      COOKBOOK_BIN = "${self'.packages.cookbook}/bin/repo";
      REDOXFS_BIN = "${self'.packages.redoxfs}/bin/redoxfs";
      INSTALLER_BIN = "${self'.packages.installer}/bin/redox_installer";

      shellHook = ''
        ${gitHooksShellHook}
        echo "RedoxOS Nix Development Environment"
        echo ""
        echo "Rust: $(rustc --version)"
        echo "Target: ${redoxTarget}"
        echo ""
        echo "Quick commands:"
        echo "  nix fmt                - Format all code"
        echo "  nix flake check        - Run all checks"
        echo ""
        echo "Build packages:"
        echo "  nix build .#cookbook   - Package manager"
        echo "  nix build .#relibc     - C library"
        echo "  nix build .#kernel     - Kernel"
        echo "  nix build .#diskImage  - Complete image"
        echo ""
        echo "Run Redox:"
        echo "  nix run .#run-redox           - Headless"
        echo "  nix run .#run-redox-graphical - Graphical"
        echo ""
      '';
    };

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
        ]);

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
        ${gitHooksShellHook}
        export LD_LIBRARY_PATH="$NIX_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
        echo "RedoxOS Native Build Environment"
        echo ""
        echo "Rust: $(rustc --version)"
        echo "Target: ${redoxTarget}"
        echo ""
        echo "Quick start: nix build .#diskImage"
      '';
    };

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

      inherit (rustEnv) RUST_SRC_PATH TARGET NEXTEST_NO_TESTS;
      PKG_CONFIG_PATH = pkgConfigPath;
      NIX_SHELL_BUILD = "1";
      PODMAN_BUILD = "0";

      shellHook = ''
        ${gitHooksShellHook}
        echo "RedoxOS Minimal Environment"
      '';
    };
  };

  # Expose git-hooks check for CI
  checks = {
    pre-commit-check = gitHooksEval;
  };
}
