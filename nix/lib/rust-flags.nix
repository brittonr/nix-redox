# Centralized RUSTFLAGS configuration for Redox cross-compilation
#
# This module defines the common RUSTFLAGS used by all cross-compiled
# Redox userspace packages. Centralizing these eliminates ~10 lines of
# duplicated configuration from each package.

{
  lib,
  pkgs,
  redoxTarget,
  relibc,
  stubLibs,
}:

rec {
  # Common linker arguments for all Redox userspace binaries
  linkerArgs = [
    "-nostdlib"
    "-static"
    "--target=${redoxTarget}"
    "${relibc}/${redoxTarget}/lib/crt0.o"
    "${relibc}/${redoxTarget}/lib/crti.o"
    "${relibc}/${redoxTarget}/lib/crtn.o"
    # Allow multiple definitions to resolve conflicts between relibc's
    # bundled core/alloc and -Z build-std versions. This is necessary
    # because relibc vendors its own copy of core/alloc for internal use.
    "-Wl,--allow-multiple-definition"
  ];

  # Linker optimizations for smaller binaries
  # These are optional but recommended for release builds
  linkerOptimizations = [
    "-Wl,--gc-sections" # Remove unused sections
    "-Wl,--icf=all" # Identical code folding
    "-Wl,-O2" # LLD optimization level
    "-Wl,--as-needed" # Only link needed libraries
  ];

  # Base RUSTFLAGS for cross-compiled Redox userspace
  # Use this for packages that need the standard library
  userRustFlags = lib.concatStringsSep " " (
    [
      # Target CPU - use baseline x86-64 to avoid advanced instructions
      # (RDRAND, SSE4, AVX) that may not be available in QEMU or older CPUs
      "-C target-cpu=x86-64"

      # Library search paths
      "-L ${relibc}/${redoxTarget}/lib"

      # Panic strategy - abort instead of unwinding (smaller binaries)
      "-C panic=abort"

      # Use clang as linker driver for cross-compilation
      "-C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
    ]
    ++ (map (arg: "-C link-arg=${arg}") linkerArgs)
  );

  # RUSTFLAGS with additional optimizations
  # Use for release builds where binary size matters
  userRustFlagsOptimized = lib.concatStringsSep " " (
    [
      userRustFlags
    ]
    ++ (map (arg: "-C link-arg=${arg}") linkerOptimizations)
  );

  # Environment variable name for Cargo
  cargoEnvVar = "CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS";

  # Common build-std configuration
  buildStdArgs = [
    "-Z build-std=core,alloc,std,panic_abort"
    "-Z build-std-features=compiler-builtins-mem"
  ];

  # Cargo profile settings for release builds
  # Can be appended to Cargo.toml or config.toml
  releaseProfile = ''
    [profile.release]
    panic = "abort"
    lto = "thin"
    codegen-units = 1
    opt-level = "s"
    strip = true
  '';

  # Helper function to set up cross-compilation environment
  mkCrossEnv =
    {
      extraFlags ? "",
    }:
    {
      ${cargoEnvVar} = if extraFlags == "" then userRustFlags else "${userRustFlags} ${extraFlags}";
      CARGO_BUILD_TARGET = redoxTarget;
    };
}
