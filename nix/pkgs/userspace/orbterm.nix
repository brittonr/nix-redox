# Orbterm - Terminal Emulator for Orbital
#
# Orbterm is a graphical terminal emulator for Redox OS that runs within
# the Orbital windowing system. It provides:
# - VT100/ANSI terminal emulation
# - TrueType font rendering
# - Copy/paste support
# - Scrollback buffer
# - UI configuration files
#
# Dependencies:
# - orbital: Display server (runtime dependency)
# - orbclient: Client library for connecting to Orbital
# - orbfont: Font rendering
# - libredox: Redox OS system library

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  orbterm-src,
  # Optional/unused inputs accepted for compatibility
  orbclient-src ? null,
  orbfont-src ? null,
  orbimage-src ? null,
  libredox-src ? null,
  relibc-src ? null,
  ...
}:

let
  # Vendor orbterm's dependencies - all from crates.io, no git deps
  orbtermVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "orbterm-cargo-vendor";
    src = orbterm-src;
    hash = "sha256-/ZLt7HMD3wXQsXSiaNEFwURJYBYOwj9TNcR8CUUjB5k=";
  };

  # Create merged vendor directory (project + sysroot)
  mergedVendor = vendor.mkMergedVendor {
    name = "orbterm";
    projectVendor = orbtermVendor;
    inherit sysrootVendor;
  };

in
pkgs.stdenv.mkDerivation {
  pname = "orbterm";
  version = "unstable";

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

    cp -r ${orbterm-src}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      gitSources = [ ]; # No git deps in orbterm
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

    export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L ${stubLibs}/lib -C panic=abort -C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang -C link-arg=-nostdlib -C link-arg=-static -C link-arg=--target=${redoxTarget} -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=-Wl,--allow-multiple-definition"

    cargo build \
      --bin orbterm \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/orbterm $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Orbterm: Terminal Emulator for Orbital on Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/orbterm";
    license = licenses.mit;
  };
}
