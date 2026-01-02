# Cross-compilation helpers for RedoxOS packages
#
# This module provides high-level functions for building Rust packages
# for the Redox target. It handles:
# - Vendor directory setup with sysroot merging
# - RUSTFLAGS configuration
# - Stub library linking
# - build-std invocation
#
# Usage:
#   crossCompile = import ./cross-compile.nix { ... };
#   ion = crossCompile.mkRedoxBinary { pname = "ion"; ... };

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  stubLibs,
  sysrootVendor,
  rustToolchain,
}:

let
  vendor = import ./vendor.nix { inherit pkgs lib; };
  rustFlags = import ./rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # Common native build inputs for all cross-compiled packages
  commonNativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.llvm
    pkgs.llvmPackages.lld
    pkgs.python3
  ];

in
rec {
  # Re-export useful components
  inherit rustFlags vendor;

  # Build a Rust package for Redox with full control
  #
  # Example:
  #   ion = mkRedoxPackage {
  #     pname = "ion-shell";
  #     src = ion-src;
  #     projectVendor = ionVendor;
  #     cargoBuildFlags = "--bin ion";
  #     installPhase = ''
  #       mkdir -p $out/bin
  #       cp target/${redoxTarget}/release/ion $out/bin/
  #     '';
  #   };
  mkRedoxPackage =
    {
      pname,
      version ? "unstable",
      src,
      projectVendor,
      cargoBuildFlags ? "",
      cargoExtraArgs ? "",
      preConfigure ? "",
      preBuild ? "",
      postBuild ? "",
      installPhase,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      meta ? { },
      gitSources ? [ ],
      ...
    }@args:
    let
      mergedVendor = vendor.mkMergedVendor {
        name = pname;
        inherit projectVendor sysrootVendor;
      };
    in
    pkgs.stdenv.mkDerivation {
      inherit pname version;

      dontUnpack = true;

      nativeBuildInputs = commonNativeBuildInputs ++ nativeBuildInputs;

      buildInputs = [ relibc ] ++ buildInputs;

      TARGET = redoxTarget;
      RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

      configurePhase = ''
        runHook preConfigure

        # Copy source with write permissions
        cp -r ${src}/* .
        chmod -R u+w .

        ${preConfigure}

        # Link merged vendor directory
        ln -s ${mergedVendor} vendor-combined

        # Create cargo config
        mkdir -p .cargo
        cat > .cargo/config.toml << 'EOF'
        ${vendor.mkCargoConfig { inherit gitSources; }}

        [build]
        target = "${redoxTarget}"

        [target.${redoxTarget}]
        linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

        [profile.release]
        panic = "abort"
        EOF

        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild

        export HOME=$(mktemp -d)
        export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"

        ${preBuild}

        cargo build \
          ${cargoBuildFlags} \
          --target ${redoxTarget} \
          --release \
          -Z build-std=core,alloc,std,panic_abort \
          -Z build-std-features=compiler-builtins-mem \
          ${cargoExtraArgs}

        ${postBuild}

        runHook postBuild
      '';

      inherit installPhase meta;
    };

  # Simpler version for packages that just need a single binary copied
  mkRedoxBinary =
    {
      pname,
      src,
      projectVendor,
      binaryName ? pname,
      cargoBuildFlags ? "--bin ${binaryName}",
      ...
    }@args:
    mkRedoxPackage (
      args
      // {
        inherit cargoBuildFlags;
        installPhase =
          args.installPhase or ''
            runHook preInstall
            mkdir -p $out/bin
            cp target/${redoxTarget}/release/${binaryName} $out/bin/
            runHook postInstall
          '';
      }
    );

  # For packages with multiple binaries
  mkRedoxMultiBinary =
    {
      pname,
      src,
      projectVendor,
      binaries,
      ...
    }@args:
    mkRedoxPackage (
      args
      // {
        installPhase =
          args.installPhase or ''
            runHook preInstall
            mkdir -p $out/bin
            ${lib.concatMapStringsSep "\n" (bin: ''
              if [ -f target/${redoxTarget}/release/${bin} ]; then
                cp target/${redoxTarget}/release/${bin} $out/bin/
              fi
            '') binaries}
            runHook postInstall
          '';
      }
    );

  # For packages that need all built executables
  mkRedoxAllBinaries =
    {
      pname,
      src,
      projectVendor,
      ...
    }@args:
    mkRedoxPackage (
      args
      // {
        installPhase =
          args.installPhase or ''
            runHook preInstall
            mkdir -p $out/bin
            find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
              ! -name "*.d" ! -name "*.rlib" ! -name "build-script-*" \
              -exec cp {} $out/bin/ \;
            runHook postInstall
          '';
      }
    );
}
