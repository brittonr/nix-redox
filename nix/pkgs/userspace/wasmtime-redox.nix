# wasmtime - WebAssembly runtime for Redox OS
#
# Cross-compiles Wasmtime v43 with the Pulley interpreter backend using
# Wasmtime's custom platform API. Redox lacks ucontext_t/sigaltstack needed
# by the unix signal handler, so we route through the custom sys module and
# provide mmap/tls platform symbols via wasmtime-platform-redox.c.
#
# Features enabled:
#   CLI: compile, cranelift, pulley, wat, logging
#   Lib: std, runtime, cranelift, pulley, wat, custom-virtual-memory
#
# The `run` subcommand is NOT available (requires WASI + tokio).
# Use `wasmtime compile` to compile .wasm -> .cwasm on the host,
# then load .cwasm on Redox with a minimal runner.
#
# Source: github.com/bytecodealliance/wasmtime v43.0.0
# Binary: wasmtime

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  wasmtime-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      ;
  };

  # Patch file that routes Redox to the custom platform module
  redoxPlatformPatch = ../../patches/wasmtime/0001-redox-custom-platform.patch;

  # C implementation of wasmtime_* platform symbols for Redox
  platformC = ./wasmtime-platform-redox.c;

  # Pre-build the platform library as a separate derivation so it's available
  # as a static library in the Nix store for the main build to link against.
  wasmtimePlatformLib = pkgs.stdenv.mkDerivation {
    pname = "wasmtime-platform-redox-lib";
    version = "43.0.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.llvmPackages.clang-unwrapped pkgs.llvmPackages.bintools ];
    buildPhase = ''
      ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
        --target=${redoxTarget} \
        --sysroot=${relibc}/${redoxTarget} \
        -I${relibc}/${redoxTarget}/include \
        -D__redox__ \
        -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
        -c ${platformC} -o wasmtime-platform-redox.o
      llvm-ar crs libwasmtime-platform-redox.a wasmtime-platform-redox.o
    '';
    installPhase = ''
      mkdir -p $out/lib
      cp libwasmtime-platform-redox.a $out/lib/
    '';
  };

in
mkUserspace.mkBinary {
  pname = "wasmtime";
  version = "43.0.0";
  src = wasmtime-src;
  binaryName = "wasmtime";

  vendorHash = "sha256-WJz7J9FHGRqni889o2omkC1K+rwZ8iM6SarT1nd1p0Q=";

  cargoBuildFlags = builtins.concatStringsSep " " [
    "--no-default-features"
    "-F compile,cranelift,pulley,wat,logging"
    "-F wasmtime/custom-virtual-memory"
    "-F wasmtime/runtime"
  ];

  preConfigure = ''
    # Apply Redox platform patches to wasmtime source
    patch -p1 < ${redoxPlatformPatch}
  '';

  # mk-userspace.nix adds "-L ${stubLibs}/lib" to RUSTFLAGS. We can't modify
  # stubLibs, but we CAN add another -L via a cargo build script in the
  # wasmtime source. The wasmtime build.rs already compiles helpers.c — we
  # patch it to also emit a link-search for our platform lib.
  postConfigure = ''
    # Append a cargo:rustc-link-search directive to wasmtime's build.rs
    # so the linker can find our platform library.
    cat >> crates/wasmtime/build.rs << 'BUILD_RS_APPEND'

// Added by Redox Nix build: link the custom platform library
fn main_redox_platform() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("redox") {
        if let Ok(lib_dir) = std::env::var("WASMTIME_PLATFORM_LIB_DIR") {
            println!("cargo:rustc-link-search=native={lib_dir}");
            println!("cargo:rustc-link-lib=static=wasmtime-platform-redox");
        }
    }
}
BUILD_RS_APPEND

    # Inject a call to main_redox_platform() in main() — add it right after
    # the default_target_pulley cfg line which is the last statement in main()
    sed -i '/custom_cfg("default_target_pulley"/a\    main_redox_platform();' crates/wasmtime/build.rs
  '';

  preBuild = ''
    # Set the env var that our build.rs addition looks for.
    # This runs inside buildPhase, before cargo build.
    export WASMTIME_PLATFORM_LIB_DIR="${wasmtimePlatformLib}/lib"
  '';

  meta = with lib; {
    description = "WebAssembly runtime (Pulley interpreter, compile-only CLI)";
    homepage = "https://wasmtime.dev";
    license = licenses.asl20;
    mainProgram = "wasmtime";
  };
}
