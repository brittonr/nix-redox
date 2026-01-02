# Nix library for RedoxOS cross-compilation
#
# This module aggregates all the shared utilities for building RedoxOS:
# - stub-libs: Unwinding stub libraries for panic=abort builds
# - rust-flags: Centralized RUSTFLAGS configuration
# - vendor: Cargo vendor merging utilities
# - cross-compile: High-level package building helpers
#
# Usage in flake.nix:
#   redoxLib = import ./nix/lib {
#     inherit pkgs lib;
#     redoxTarget = "x86_64-unknown-redox";
#   };
#
#   # Use the stub libraries
#   stubLibs = redoxLib.stubLibs;
#
#   # Get RUSTFLAGS (after relibc is built)
#   rustFlags = redoxLib.mkRustFlags { inherit relibc; };
#
#   # Build a cross-compiled package (after all deps are ready)
#   crossCompile = redoxLib.mkCrossCompile {
#     inherit relibc sysrootVendor rustToolchain;
#   };
#   ion = crossCompile.mkRedoxBinary { ... };

{ pkgs, lib, redoxTarget ? "x86_64-unknown-redox" }:

let
  # Import individual modules
  stubLibsModule = import ./stub-libs.nix { inherit pkgs redoxTarget; };
  vendorModule = import ./vendor.nix { inherit pkgs lib; };

in rec {
  # Stub libraries for unwinding (built once, used by all packages)
  stubLibs = stubLibsModule;

  # RUSTFLAGS configuration (requires relibc to be passed in)
  mkRustFlags = { relibc }: import ./rust-flags.nix {
    inherit lib pkgs redoxTarget relibc;
    stubLibs = stubLibsModule;
  };

  # Cross-compilation helpers (requires all deps to be passed in)
  mkCrossCompile = { relibc, sysrootVendor, rustToolchain }:
    import ./cross-compile.nix {
      inherit pkgs lib redoxTarget relibc sysrootVendor rustToolchain;
      stubLibs = stubLibsModule;
    };

  # Vendor management utilities
  vendor = vendorModule;

  # Convenience re-exports
  inherit (vendorModule) mkMergedVendor mkCargoConfig mergeVendorsScript;

  # Target configuration
  target = {
    arch = builtins.head (lib.splitString "-" redoxTarget);
    triple = redoxTarget;
    uefi = "${builtins.head (lib.splitString "-" redoxTarget)}-unknown-uefi";
  };

  # Common build-std arguments (as a string for cargo)
  buildStdArgs = "-Z build-std=core,alloc,std,panic_abort -Z build-std-features=compiler-builtins-mem";

  # Common native build inputs for cross-compilation
  commonNativeBuildInputs = with pkgs; [
    gnumake
    nasm
    llvmPackages.clang-unwrapped
    llvmPackages.llvm
    llvmPackages.lld
    python3
  ];
}
