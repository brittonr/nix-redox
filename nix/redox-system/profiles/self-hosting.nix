# Self-Hosting RedoxOS Profile
#
# Full development environment PLUS Rust compiler toolchain.
# Can compile and link Rust programs FROM WITHIN the running Redox OS.
#
# Includes:
#   - Everything from development profile (editors, CLI tools, networking)
#   - rustc + cargo + rustdoc (Rust compiler toolchain)
#   - Minimal LLVM (clang, lld, llvm-ar — used as linker backend)
#   - relibc sysroot (headers + static libs for linking)
#   - CC wrapper script (bridges rustc → clang → lld)
#   - Pre-configured .cargo/config.toml for the Redox target
#
# Disk size: 4096 MB (toolchain is ~600 MB)
#
# Usage:
#   nix build .#redox-self-hosting
#   nix run .#run-redox-self-hosting
#
# On-guest:
#   mkdir hello && cd hello
#   cargo init
#   cargo build          # Just Works™

{ pkgs, lib }:

let
  dev = import ./development.nix { inherit pkgs lib; };
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
dev
// {
  "/boot" = (dev."/boot" or { }) // {
    # Toolchain is ~600MB, relibc sysroot ~130MB, plus base system ~300MB
    diskSizeMB = 4096;
  };

  "/environment" = (dev."/environment" or { }) // {
    systemPackages =
      (dev."/environment".systemPackages or [ ])
      # Rust toolchain
      ++ opt "redox-rustc"
      # C++ runtime shim (libstdc++.so.6 from libc++ — needed by librustc_driver.so)
      ++ opt "redox-libstdcxx-shim"
      # Minimal LLVM (clang as CC, lld as linker, llvm-ar as archiver)
      ++ opt "redox-llvm"
      # relibc sysroot (headers + libs for linking)
      ++ opt "redox-sysroot"
      # cmake for C/C++ projects
      ++ opt "redox-cmake"
      # Stack-growing lld launcher (fixes JOBS>=2 linker crashes)
      ++ opt "lld-wrapper";

    variables = (dev."/environment".variables or { }) // {
      # Point cargo/rustc at the sysroot for linking
      # These are picked up by the CC wrapper and cargo config
      REDOX_SYSROOT = "/usr/lib/redox-sysroot/sysroot";
      # Redox's relibc doesn't support sysconf(_SC_NPROCESSORS_ONLN) yet,
      # so std::thread::available_parallelism() panics. Set jobs explicitly.
      CARGO_BUILD_JOBS = "4";
    };
  };

  # Larger VM for compilation workloads
  "/virtualisation" = (dev."/virtualisation" or { }) // {
    memorySize = 4096;
    cpus = 4;
  };
}
