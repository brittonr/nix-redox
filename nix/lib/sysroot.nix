# Sysroot vendor management for Redox cross-compilation
#
# This module handles vendoring of the Rust standard library dependencies
# needed for `-Z build-std` cross-compilation on targets that don't ship
# pre-compiled rlibs in the toolchain.
#
# NOTE: As of nightly-2025-10-03, the Rust toolchain ships pre-compiled
# rlibs for x86_64-unknown-redox. Userspace and system packages no longer
# need -Z build-std — they use the toolchain's rlibs directly.
# The sysroot vendor is still available for any future targets that
# don't ship pre-compiled rlibs.
#
# Usage:
#   sysrootLib = import ./sysroot.nix { inherit pkgs lib rustToolchain redoxTarget; };
#   sysrootVendor = sysrootLib.vendor;
#   sysroot = sysrootLib.mkSysroot { inherit relibc; };

{
  pkgs,
  lib,
  rustToolchain,
  redoxTarget,
}:

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
    {
      relibc,
      stubLibs ? null,
    }:
    pkgs.symlinkJoin {
      name = "redox-sysroot";
      paths = [
        rustToolchain
        relibc
      ];
    };

  # Common build-std arguments for cross-compilation
  # These are only needed for targets where the toolchain doesn't ship
  # pre-compiled rlibs (e.g., kernel no_std, UEFI bootloader).
  buildStdArgs = "-Z build-std=core,alloc,std,panic_abort -Z build-std-features=compiler-builtins-mem";

  # Build-std arguments as a list (for Nix list manipulation)
  buildStdArgsList = [
    "-Z build-std=core,alloc,std,panic_abort"
    "-Z build-std-features=compiler-builtins-mem"
  ];

  # Minimal build-std for no_std targets (kernel, bootloader)
  buildStdArgsNoStd = "-Z build-std=core,alloc -Z build-std-features=compiler-builtins-mem";
}
