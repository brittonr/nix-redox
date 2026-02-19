# netcfg-setup - Network configuration tool for Redox OS
#
# Replaces three generated Ion scripts (netcfg-auto, netcfg-static, netcfg-ch)
# with a single Rust binary. Uses proper sleep() instead of spin-loops,
# structured error handling, and best-effort scheme writes.
#
# Subcommands:
#   auto   — DHCP with static fallback (replaces netcfg-auto)
#   static — Explicit static config (replaces netcfg-static)
#   cloud  — Cloud Hypervisor config (replaces netcfg-ch)

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
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  src = ../../../src/netcfg-setup;

  # No external crate dependencies — sysroot vendor is all we need for -Z build-std.
  # Create a merged vendor from an empty project vendor + sysroot.
  emptyVendor = pkgs.runCommand "netcfg-setup-empty-vendor" { } ''
    mkdir -p $out
  '';

  mergedVendor = vendor.mkMergedVendor {
    name = "netcfg-setup";
    projectVendor = emptyVendor;
    inherit sysrootVendor;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "netcfg-setup";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
  ];

  buildInputs = [ relibc ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    cp -r ${src}/* .
    chmod -R u+w .

    # Only sysroot vendor needed (no external deps)
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      gitSources = [ ];
      target = redoxTarget;
      linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
      panic = "abort";
    }}
    CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)
    export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"
    export ${rustFlags.ccEnvVar}="${rustFlags.ccBin}"
    export ${rustFlags.cflagsEnvVar}="${rustFlags.cFlags}"

    cargo build \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/netcfg-setup $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Network configuration tool for Redox OS";
    license = licenses.mit;
  };
}
