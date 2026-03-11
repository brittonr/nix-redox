# Userspace package builder for Redox OS
#
# This module provides helper functions for building cross-compiled Rust
# packages for the Redox target. It handles:
# - Pre-compiled sysroot injection (--sysroot instead of -Z build-std)
# - Vendor directory management (no sysroot merge needed with prebuilt sysroot)
# - Stub library linking (for panic=abort builds)
# - RUSTFLAGS configuration
# - Cargo config generation
#
# When combinedSysroot is provided, packages skip -Z build-std entirely
# and use pre-compiled stdlib rlibs, saving ~60-90s per package.
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
  # Accept but ignore (passed via userspaceArgs/standaloneCommon)
  ...
}:

let
  # Import rust-flags — useToolchainRlibs=true by default, so buildStdArgs is empty
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # With toolchain rlibs, no sysroot vendor merge needed
  needsBuildStd = !rustFlags.useToolchainRlibs;

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

      # Create vendor directory:
      # - With prebuilt sysroot: just the project vendor (no sysroot merge needed)
      # - Without: merged project + sysroot vendor (legacy path)
      mergedVendor = vendor.mkMergedVendor {
        name = pname;
        inherit projectVendor;
        sysrootVendor = if needsBuildStd then sysrootVendor else null;
      };
    in
    pkgs.stdenv.mkDerivation {
      inherit pname version;

      dontUnpack = true;

      nativeBuildInputs = commonNativeBuildInputs ++ nativeBuildInputs;

      buildInputs = [ relibc ] ++ buildInputs;

      TARGET = redoxTarget;

      # RUST_SRC_PATH only needed for -Z build-std (to find stdlib source)
      RUST_SRC_PATH = lib.optionalString needsBuildStd "${rustToolchain}/lib/rustlib/src/rust/library";

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
        # When combinedSysroot is set, this includes --sysroot pointing to
        # pre-compiled stdlib rlibs (no -Z build-std needed)
        export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"

        # Set C compiler flags for cross-compilation so cc-rs uses relibc headers
        # instead of glibc (which has unsupported __float128 on newer glibc versions)
        export ${rustFlags.ccEnvVar}="${rustFlags.ccBin}"
        export ${rustFlags.cflagsEnvVar}="${rustFlags.cFlags}"

        # Build the package
        cargo build \
          ${cargoBuildFlags} \
          --target ${redoxTarget} \
          --release \
          ${lib.concatStringsSep " \\\n          " rustFlags.buildStdArgs}

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
    let
      cleanArgs = builtins.removeAttrs args [ "binaries" ];
    in
    mkPackage (
      cleanArgs
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
