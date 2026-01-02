# Sysroot vendor management for Redox cross-compilation
#
# This module handles vendoring of the Rust standard library dependencies
# needed for `-Z build-std` cross-compilation. It creates a fixed-output
# derivation that works with the Nix sandbox.
#
# Usage:
#   sysrootLib = import ./sysroot.nix { inherit pkgs rustToolchain; };
#   sysrootVendor = sysrootLib.vendor;
#   sysroot = sysrootLib.mkSysroot { inherit relibc; };

{ pkgs, rustToolchain }:

let
  # Source directory with sysroot Cargo.toml and Cargo.lock
  sysrootSrc = pkgs.runCommand "rust-sysroot-src" { } ''
    mkdir -p $out/sysroot
    cp -L ${rustToolchain}/lib/rustlib/src/rust/library/Cargo.lock $out/
    cp -L ${rustToolchain}/lib/rustlib/src/rust/library/Cargo.toml $out/
    cp -L ${rustToolchain}/lib/rustlib/src/rust/library/sysroot/Cargo.toml $out/sysroot/
    # Copy workspace member manifests
    for dir in std core alloc proc_macro test panic_abort panic_unwind \
               profiler_builtins compiler-builtins portable-simd backtrace \
               rustc-std-workspace-core rustc-std-workspace-alloc \
               rustc-std-workspace-std rtstartup; do
      if [ -d ${rustToolchain}/lib/rustlib/src/rust/library/$dir ]; then
        mkdir -p $out/$dir
        cp -L ${rustToolchain}/lib/rustlib/src/rust/library/$dir/Cargo.toml $out/$dir/ 2>/dev/null || true
      fi
    done
  '';

in
rec {
  # The source directory for sysroot vendoring
  src = sysrootSrc;

  # Vendored sysroot dependencies (fixed-output derivation)
  # This hash must be updated when rustToolchain version changes
  vendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "rust-sysroot-vendor";
    src = sysrootSrc;
    hash = "sha256-wlOI8bZRUmc18GN4Bpx74eYlUQODJzxBk5Ia5IwXm14=";
  };

  # Create a combined sysroot with relibc
  mkSysroot =
    { relibc }:
    pkgs.symlinkJoin {
      name = "redox-sysroot";
      paths = [
        rustToolchain
        relibc
      ];
    };

  # Common build-std arguments for cross-compilation
  buildStdArgs = "-Z build-std=core,alloc,std,panic_abort -Z build-std-features=compiler-builtins-mem";

  # Build-std arguments as a list (for Nix list manipulation)
  buildStdArgsList = [
    "-Z build-std=core,alloc,std,panic_abort"
    "-Z build-std-features=compiler-builtins-mem"
  ];

  # Minimal build-std for no_std targets (kernel, bootloader)
  buildStdArgsNoStd = "-Z build-std=core,alloc -Z build-std-features=compiler-builtins-mem";
}
