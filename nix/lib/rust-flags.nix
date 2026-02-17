# Centralized RUSTFLAGS and cross-compilation configuration for Redox
#
# This module defines all flags used by cross-compiled Redox packages.
# Centralizing these eliminates duplicated configuration scattered across
# individual package files.
#
# Provides:
#   - RUSTFLAGS for userspace (clang linker) and system (ld.lld) packages
#   - CC/CFLAGS for the cc-rs crate (C code in build scripts)
#   - Environment variable names derived from target triple (not hardcoded)
#   - Composable mkRustFlagsString for custom configurations

{
  lib,
  pkgs,
  redoxTarget,
  relibc,
  stubLibs,
}:

let
  # Derive env var suffixes from target triple.
  # Cargo uses CARGO_TARGET_<UPPER_SNAKE>_RUSTFLAGS.
  # cc-rs uses CC_<snake> / CFLAGS_<snake> (preserves original case).
  cargoTargetSuffix = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] redoxTarget);
  ccTargetSuffix = builtins.replaceStrings [ "-" ] [ "_" ] redoxTarget;

  # Paths used in multiple flag sets
  clangBin = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";

  crtObjects = [
    "${relibc}/${redoxTarget}/lib/crt0.o"
    "${relibc}/${redoxTarget}/lib/crti.o"
    "${relibc}/${redoxTarget}/lib/crtn.o"
  ];

in
rec {
  # === Environment Variable Names (derived from target, not hardcoded) ===

  # CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS (etc.)
  cargoEnvVar = "CARGO_TARGET_${cargoTargetSuffix}_RUSTFLAGS";

  # CC_x86_64_unknown_redox / CFLAGS_x86_64_unknown_redox (etc.)
  ccEnvVar = "CC_${ccTargetSuffix}";
  cflagsEnvVar = "CFLAGS_${ccTargetSuffix}";

  # === C Compiler Configuration (for cc-rs crate) ===

  ccBin = clangBin;

  cFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "-D__redox__"
    "-U_FORTIFY_SOURCE"
    "-D_FORTIFY_SOURCE=0"
    "-I${relibc}/${redoxTarget}/include"
    "--sysroot=${relibc}/${redoxTarget}"
  ];

  # === RUSTFLAGS Generation ===

  # Composable RUSTFLAGS builder.
  #
  # Parameters:
  #   useClangLinker: Use clang as linker driver (default) vs ld.lld directly.
  #                   Affects whether --target and -Wl, prefix are included.
  #   includePanic:   Include -C panic=abort (userspace uses this; base sets
  #                   it in Cargo.toml profile instead).
  #   extraLibPaths:  Additional -L paths (e.g., stubLibs).
  mkRustFlagsString =
    {
      useClangLinker ? true,
      includePanic ? true,
      extraLibPaths ? [ ],
    }:
    let
      wlPrefix = if useClangLinker then "-Wl," else "";
    in
    lib.concatStringsSep " " (
      [
        # Target CPU — baseline x86-64 avoids advanced instructions
        # (RDRAND, SSE4, AVX) that may not be available in QEMU/older CPUs
        "-C target-cpu=x86-64"

        # Library search path for relibc
        "-L ${relibc}/${redoxTarget}/lib"
      ]
      ++ (map (p: "-L ${p}") extraLibPaths)
      ++ (lib.optional includePanic "-C panic=abort")
      ++ (lib.optional useClangLinker "-C linker=${clangBin}")
      ++ (map (arg: "-C link-arg=${arg}") (
        [
          "-nostdlib"
          "-static"
        ]
        ++ (lib.optional useClangLinker "--target=${redoxTarget}")
        ++ crtObjects
        ++ [
          # Allow multiple definitions to resolve conflicts between relibc's
          # bundled core/alloc and -Z build-std versions.
          "${wlPrefix}--allow-multiple-definition"
        ]
      ))
    );

  # Standard RUSTFLAGS for userspace packages (clang linker, panic=abort).
  # Most packages use this + "-L ${stubLibs}/lib" appended at the call site.
  userRustFlags = mkRustFlagsString { };

  # RUSTFLAGS for system packages like base (ld.lld via cargo config, no
  # explicit panic — set in Cargo.toml profile instead).
  systemRustFlags = mkRustFlagsString {
    useClangLinker = false;
    includePanic = false;
  };

  # RUSTFLAGS with linker optimizations for smaller binaries
  userRustFlagsOptimized = lib.concatStringsSep " " (
    [ userRustFlags ] ++ (map (arg: "-C link-arg=${arg}") linkerOptimizations)
  );

  # === Linker Optimizations (optional, for release builds) ===

  linkerOptimizations = [
    "-Wl,--gc-sections" # Remove unused sections
    "-Wl,--icf=all" # Identical code folding
    "-Wl,-O2" # LLD optimization level
    "-Wl,--as-needed" # Only link needed libraries
  ];

  # === Common Build-std Arguments ===

  buildStdArgs = [
    "-Z build-std=core,alloc,std,panic_abort"
    "-Z build-std-features=compiler-builtins-mem"
  ];

  # === Cargo Profile Settings ===

  releaseProfile = ''
    [profile.release]
    panic = "abort"
    lto = "thin"
    codegen-units = 1
    opt-level = "s"
    strip = true
  '';

  # === Helper: Full Cross-Env Shell Script Fragment ===
  #
  # Returns a shell snippet that exports RUSTFLAGS, CC, and CFLAGS.
  # Usage in buildPhase:
  #   ${rustFlags.mkCrossEnvScript {}}
  mkCrossEnvScript =
    {
      extraRustFlags ? "",
      includeStubLibs ? true,
      includeCc ? true,
      rustFlagsBase ? userRustFlags,
    }:
    let
      stubLibPath = lib.optionalString includeStubLibs " -L ${stubLibs}/lib";
      extraFlags = lib.optionalString (extraRustFlags != "") " ${extraRustFlags}";
    in
    ''
      export ${cargoEnvVar}="${rustFlagsBase}${stubLibPath}${extraFlags}"
    ''
    + lib.optionalString includeCc ''
      export ${ccEnvVar}="${ccBin}"
      export ${cflagsEnvVar}="${cFlags}"
    '';
}
