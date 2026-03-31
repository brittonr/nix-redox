# boot-log-sink — register a rootfs file as a logd output sink
#
# Opens /var/log/boot.log and sends the fd to logd via its add_sink
# interface. logd backfills all buffered lines (up to 1000) and
# continues forwarding new log output to the file.
#
# Zero external crate dependencies — uses raw Redox syscalls.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  ...
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

  src = ../../../src/boot-log-sink;

  emptyVendor = pkgs.runCommand "boot-log-sink-empty-vendor" { } ''
    mkdir -p $out
  '';

  mergedVendor = vendor.mkMergedVendor {
    name = "boot-log-sink";
    projectVendor = emptyVendor;
    inherit sysrootVendor;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "boot-log-sink";
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
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/boot-log-sink $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Boot log sink for Redox OS — captures logd output to /var/log/boot.log";
    license = licenses.mit;
  };
}
