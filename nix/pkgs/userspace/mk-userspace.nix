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
    inherit lib pkgs redoxTarget relibc stubLibs;
  };

  # Common native build inputs for all userspace packages
  commonNativeBuildInputs = [
    rustToolchain
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
    pkgs.python3
  ];

  # Generate cargo config content
  mkCargoConfigContent = { gitSources ? [] }: ''
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor-combined"

    ${lib.concatMapStringsSep "\n" (src: ''
    [source."${src.url}"]
    git = "${src.git}"
    ${lib.optionalString (src ? branch) "branch = \"${src.branch}\""}
    ${lib.optionalString (src ? rev) "rev = \"${src.rev}\""}
    replace-with = "vendored-sources"
    '') gitSources}

    [net]
    offline = true

    [build]
    target = "${redoxTarget}"

    [target.${redoxTarget}]
    linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

    [profile.release]
    panic = "abort"
  '';

  # Python script for regenerating checksums
  checksumScript = vendor.checksumScript;

in rec {
  # Build a generic Rust package for Redox
  mkPackage = {
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
    nativeBuildInputs ? [],
    buildInputs ? [],
    gitSources ? [],
    meta ? {},
  }:
  let
    # Vendor project dependencies
    projectVendor = pkgs.rustPlatform.fetchCargoVendor {
      name = "${pname}-cargo-vendor";
      inherit src;
      hash = vendorHash;
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

      # Merge project + sysroot vendors with version conflict resolution
      mkdir -p vendor-combined

      get_version() {
        grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
      }

      # Copy project vendor crates
      for crate in ${projectVendor}/*/; do
        crate_name=$(basename "$crate")
        if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
          continue
        fi
        if [ -d "$crate" ]; then
          cp -rL "$crate" "vendor-combined/$crate_name"
        fi
      done
      chmod -R u+w vendor-combined/

      # Merge sysroot vendor with version conflict resolution
      for crate in ${sysrootVendor}/*/; do
        crate_name=$(basename "$crate")
        if [ ! -d "$crate" ]; then
          continue
        fi
        if [ -d "vendor-combined/$crate_name" ]; then
          base_version=$(get_version "vendor-combined/$crate_name")
          sysroot_version=$(get_version "$crate")
          if [ "$base_version" != "$sysroot_version" ]; then
            versioned_name="$crate_name-$sysroot_version"
            if [ ! -d "vendor-combined/$versioned_name" ]; then
              cp -rL "$crate" "vendor-combined/$versioned_name"
            fi
          fi
        else
          cp -rL "$crate" "vendor-combined/$crate_name"
        fi
      done
      chmod -R u+w vendor-combined/

      # Regenerate checksums
      ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
      ${checksumScript}
      PYTHON_CHECKSUM

      # Create cargo config
      mkdir -p .cargo
      cat > .cargo/config.toml << 'CARGOCONF'
      ${mkCargoConfigContent { inherit gitSources; }}
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
  mkBinary = {
    pname,
    binaryName ? pname,
    cargoBuildFlags ? "--bin ${binaryName}",
    ...
  }@args:
    let
      # Remove binaryName from args before passing to mkPackage
      cleanArgs = builtins.removeAttrs args [ "binaryName" ];
    in
    mkPackage (cleanArgs // {
      inherit cargoBuildFlags;
      installPhase = args.installPhase or ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/${binaryName} $out/bin/
        runHook postInstall
      '';
    });

  # Helper for packages with multiple binaries
  mkMultiBinary = {
    pname,
    binaries,
    ...
  }@args:
    mkPackage (args // {
      installPhase = args.installPhase or ''
        runHook preInstall
        mkdir -p $out/bin
        ${lib.concatMapStringsSep "\n" (bin: ''
          if [ -f target/${redoxTarget}/release/${bin} ]; then
            cp target/${redoxTarget}/release/${bin} $out/bin/
          fi
        '') binaries}
        runHook postInstall
      '';
    });
}
