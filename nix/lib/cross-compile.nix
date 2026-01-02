# Cross-compilation helpers for RedoxOS userspace packages
#
# This module provides a high-level function for building Rust packages
# for the Redox target. It handles:
# - Vendor directory setup with sysroot merging
# - RUSTFLAGS configuration
# - Stub library linking
# - build-std invocation

{ pkgs, lib, redoxTarget, relibc, stubLibs, sysrootVendor, rustToolchain }:

let
  vendor = import ./vendor.nix { inherit pkgs lib; };
  rustFlags = import ./rust-flags.nix { inherit lib pkgs redoxTarget relibc stubLibs; };

in rec {
  # Build a Rust package for Redox
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
  mkRedoxPackage = {
    pname,
    version ? "unstable",
    src,
    projectVendor,
    cargoBuildFlags ? "",
    cargoExtraArgs ? "",
    preBuild ? "",
    postBuild ? "",
    installPhase,
    nativeBuildInputs ? [],
    buildInputs ? [],
    meta ? {},
    gitSources ? [],
    ...
  }@args:
  let
    mergedVendor = vendor.mkMergedVendor {
      name = pname;
      inherit projectVendor sysrootVendor;
    };
  in pkgs.stdenv.mkDerivation {
    inherit pname version;

    dontUnpack = true;

    nativeBuildInputs = [
      rustToolchain
      pkgs.gnumake
      pkgs.llvmPackages.llvm
      pkgs.llvmPackages.lld
      pkgs.python3
    ] ++ nativeBuildInputs;

    inherit buildInputs;

    configurePhase = ''
      runHook preConfigure

      # Copy source with write permissions
      cp -r ${src}/* .
      chmod -R u+w .

      # Link merged vendor directory
      ln -s ${mergedVendor} vendor-combined

      # Create cargo config
      mkdir -p .cargo
      cat > .cargo/config.toml << 'EOF'
      ${vendor.mkCargoConfig { inherit gitSources; }}
      EOF

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)
      export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags}"

      ${preBuild}

      cargo build \
        ${cargoBuildFlags} \
        --target ${redoxTarget} \
        --release \
        ${rustFlags.buildStdArgs} \
        ${cargoExtraArgs}

      ${postBuild}

      runHook postBuild
    '';

    inherit installPhase;

    inherit meta;
  };

  # Simpler version for packages that just need a binary copied
  mkRedoxBinary = {
    pname,
    src,
    projectVendor,
    binaryName ? pname,
    cargoBuildFlags ? "--bin ${binaryName}",
    ...
  }@args:
    mkRedoxPackage (args // {
      inherit cargoBuildFlags;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/${binaryName} $out/bin/
        runHook postInstall
      '';
    });
}
