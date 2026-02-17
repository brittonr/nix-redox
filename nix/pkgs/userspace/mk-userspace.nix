# Userspace package builder for Redox OS
#
# This module provides helper functions for building cross-compiled Rust
# packages for the Redox target. It handles:
# - Vendor directory merging (project + sysroot)
# - Stub library linking (for panic=abort builds)
# - RUSTFLAGS configuration
# - Cargo config generation
#
# Usage:
#   mkUserspace = import ./mk-userspace.nix { ... };
#
#   ion = mkUserspace.mkBinary {
#     pname = "ion-shell";
#     src = ion-src;
#     vendorHash = "sha256-...";
#     binaryName = "ion";
#   };

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  craneLib ? null,
}:

let
  # Import rust-flags for centralized RUSTFLAGS
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # Common native build inputs for all userspace packages
  commonNativeBuildInputs = [
    rustToolchain
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
  ];

in
rec {
  # Build a generic Rust package for Redox
  mkPackage =
    {
      pname,
      version ? "unstable",
      src,
      vendorHash,
      cargoBuildFlags ? "",
      preConfigure ? "",
      postConfigure ? "",
      preBuild ? "",
      postBuild ? "",
      installPhase,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      gitSources ? [ ],
      meta ? { },
    }:
    let
      # Vendor project dependencies
      projectVendor = pkgs.rustPlatform.fetchCargoVendor {
        name = "${pname}-cargo-vendor";
        inherit src;
        hash = vendorHash;
      };

      # Create merged vendor directory (cached as separate derivation)
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

        # Use pre-merged vendor directory
        cp -rL ${mergedVendor} vendor-combined
        chmod -R u+w vendor-combined

        # Create cargo config
        mkdir -p .cargo
        cat > .cargo/config.toml << 'CARGOCONF'
        ${vendor.mkCargoConfig {
          inherit gitSources;
          target = redoxTarget;
          linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
          panic = "abort";
        }}
        CARGOCONF

        ${postConfigure}

        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild

        export HOME=$(mktemp -d)

        ${preBuild}

        # Set RUSTFLAGS for cross-compilation
        export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"

        # Set C compiler flags for cross-compilation so cc-rs uses relibc headers
        # instead of glibc (which has unsupported __float128 on newer glibc versions)
        export CC_x86_64_unknown_redox="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
        export CFLAGS_x86_64_unknown_redox="--target=${redoxTarget} -D__redox__ -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -I${relibc}/${redoxTarget}/include --sysroot=${relibc}/${redoxTarget}"

        # Build the package
        cargo build \
          ${cargoBuildFlags} \
          --target ${redoxTarget} \
          --release \
          -Z build-std=core,alloc,std,panic_abort \
          -Z build-std-features=compiler-builtins-mem

        ${postBuild}

        runHook postBuild
      '';

      inherit installPhase meta;
    };

  # Simplified helper for packages that just install a single binary
  mkBinary =
    {
      pname,
      binaryName ? pname,
      cargoBuildFlags ? "--bin ${binaryName}",
      ...
    }@args:
    let
      # Remove binaryName from args before passing to mkPackage
      cleanArgs = builtins.removeAttrs args [ "binaryName" ];
    in
    mkPackage (
      cleanArgs
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

  # Helper for packages with multiple binaries
  mkMultiBinary =
    {
      pname,
      binaries,
      ...
    }@args:
    mkPackage (
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
}
