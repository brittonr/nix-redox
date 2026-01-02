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
#   # Use the stub libraries (built once, used by all packages)
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
#
# For package definitions, see ../pkgs/default.nix

{ pkgs, lib, redoxTarget ? "x86_64-unknown-redox" }:

let
  # Import individual modules
  stubLibsModule = import ./stub-libs.nix { inherit pkgs redoxTarget; };
  vendorModule = import ./vendor.nix { inherit pkgs lib; };

in rec {
  # Stub libraries for unwinding (built once, used by all packages)
  # These provide empty _Unwind_* symbols required by Rust's panic infrastructure
  # but never called when building with panic=abort
  stubLibs = stubLibsModule;

  # RUSTFLAGS configuration factory (requires relibc to be passed in)
  # Returns an attrset with:
  # - userRustFlags: The complete RUSTFLAGS string
  # - cargoEnvVar: The correct env var name for Cargo
  # - buildStdArgs: Arguments for -Z build-std
  mkRustFlags = { relibc }: import ./rust-flags.nix {
    inherit lib pkgs redoxTarget relibc;
    stubLibs = stubLibsModule;
  };

  # Cross-compilation helpers factory (requires all deps to be passed in)
  # Returns an attrset with:
  # - mkRedoxPackage: Full control over package building
  # - mkRedoxBinary: Simple single-binary packages
  # - mkRedoxMultiBinary: Packages with multiple named binaries
  # - mkRedoxAllBinaries: Packages where all executables should be installed
  mkCrossCompile = { relibc, sysrootVendor, rustToolchain }:
    import ./cross-compile.nix {
      inherit pkgs lib redoxTarget relibc sysrootVendor rustToolchain;
      stubLibs = stubLibsModule;
    };

  # Vendor management utilities
  # - checksumScript: Python script for regenerating vendor checksums
  # - mergeVendorsScript: Shell script for version-aware vendor merging
  # - mkMergedVendor: Derivation that produces merged vendor directory
  # - mkCargoConfig: Generate .cargo/config.toml for vendored builds
  vendor = vendorModule;

  # Convenience re-exports from vendor module
  inherit (vendorModule) mkMergedVendor mkCargoConfig mergeVendorsScript checksumScript;

  # Target configuration
  target = {
    arch = builtins.head (lib.splitString "-" redoxTarget);
    triple = redoxTarget;
    uefi = "${builtins.head (lib.splitString "-" redoxTarget)}-unknown-uefi";
  };

  # Common build-std arguments (as a list for Nix concatenation)
  buildStdArgsList = [
    "-Z build-std=core,alloc,std,panic_abort"
    "-Z build-std-features=compiler-builtins-mem"
  ];

  # Common build-std arguments (as a string for shell commands)
  buildStdArgs = lib.concatStringsSep " " buildStdArgsList;

  # Common native build inputs for cross-compilation
  # These are tools that run on the build machine
  commonNativeBuildInputs = with pkgs; [
    gnumake
    nasm
    llvmPackages.clang-unwrapped
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.llvm
    llvmPackages.lld
    python3
  ];

  # Common build inputs for host tools
  commonHostBuildInputs = with pkgs; [
    fuse
    fuse3
    openssl
    zlib
    expat
  ];
}
