# Per-crate cross-compilation for the Redox kernel via buildRustCrate.
#
# Similar to redox-buildRustCrate.nix but targets x86_64-unknown-kernel
# (a custom JSON target spec for no_std, soft-float, kernel code model).
#
# The kernel target differs from userspace:
# - Custom JSON target spec (not a standard triple)
# - rust-lld as linker (set in the JSON spec, no wrapper needed)
# - no_std (no CRT objects, no libc)
# - Kernel crate needs linker script args and nasm for build.rs

{
  pkgs,
  lib,
  rustToolchain,
  kernelTargetSpec,
}:

let
  # Minimal kernel host platform for buildRustCrate's cross-compilation checks.
  # Triggers --target flag when hostPlatform != buildPlatform.
  kernelHostPlatform = {
    config = "x86_64-unknown-kernel";
    system = "x86_64-none";
    linker = "rust-lld";
    isLinux = false;
    isDarwin = false;
    isWindows = false;
    isx86_64 = true;
    is64bit = true;
    isILP32 = false;
    extensions = {
      library = ".a";
      executable = "";
      sharedLibrary = ".so";
    };
    parsed = {
      cpu = {
        name = "x86_64";
        bits = 64;
        significantByte.name = "littleEndian";
      };
      vendor.name = "unknown";
      kernel.name = "none";
      abi.name = "";
    };
    rust = {
      rustcTarget = "x86_64-unknown-kernel";
      # Use the JSON spec path so buildRustCrate passes --target <path>.json
      rustcTargetSpec = kernelTargetSpec;
      platform = {
        arch = "x86_64";
        os = "none";
      };
    };
  };

  # The kernel target JSON spec sets linker="rust-lld", linker-flavor="gnu-lld".
  # However, buildRustCrate overrides the linker with `-C linker=<cc>`.
  # Provide a CC wrapper that delegates to the toolchain's rust-lld so the
  # linker invocation from buildRustCrate reaches the correct binary.
  rustLld = "${rustToolchain}/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld";
  dummyCc = pkgs.runCommand "kernel-cc" { } ''
    mkdir -p $out/bin
    cat > $out/bin/cc << 'SCRIPT'
    #!/bin/sh
    exec ${rustLld} "$@"
    SCRIPT
    chmod +x $out/bin/cc
  '';

  crossStdenv = pkgs.stdenv // {
    hostPlatform = kernelHostPlatform;
    cc = dummyCc // {
      targetPrefix = "";
    };
    hasCC = true;
  };

  # Extra rustc opts injected into every kernel crate.
  # --target is handled by crossStdenv (hostPlatform.rust.rustcTargetSpec).
  # -C panic=abort is required (no unwinding in kernel mode).
  kernelExtraOpts = [
    "-C"
    "panic=abort"
    "-C"
    "debuginfo=2"
  ];

  baseBRC = pkgs.buildRustCrate.override {
    rustc = rustToolchain;
    cargo = rustToolchain;
    stdenv = crossStdenv;
  };

  # Wrap to inject extraRustcOpts into every crate.
  # Also suppresses the host sysroot to prevent duplicate lang items
  # (build-std core vs host core).
  wrapBRC = brc: {
    __functor =
      _self: crateAttrs:
      brc (
        crateAttrs
        // {
          extraRustcOpts = (crateAttrs.extraRustcOpts or [ ]) ++ kernelExtraOpts;
        }
      );
    override = newArgs: wrapBRC (brc.override newArgs);
  };

in
wrapBRC baseBRC
