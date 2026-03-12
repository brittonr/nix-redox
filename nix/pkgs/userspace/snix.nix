# snix — Nix evaluator and binary cache client for Redox OS
#
# Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
# Cross-compiles to x86_64-unknown-redox with zero platform-specific code.
#
# snix-eval is vendored locally from https://git.snix.dev/snix/snix.git
# at commit eee477929d6b500936556e2f8a4e187d37525365 (2026-02-05).
# Local vendoring avoids git deps in Cargo.lock which break fetchCargoVendor
# FOD reference checks in Nix 2.31+. The Redox OS platform patch
# (is_second_coordinate) is applied directly in the vendored source.
#
# Binary: snix
# Commands: eval, show-derivation, fetch, path-info, store-verify, repl
#
# Source: in-tree (snix-redox/)

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  unit2nixVendor,
  snix-redox-src,
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
      unit2nixVendor
      ;
  };

in
mkUserspace.mkBinary {
  pname = "snix-redox";
  version = "0.4.0";
  src = snix-redox-src;
  binaryName = "snix";

  # Vendor hash — all dependencies are from crates.io (no git sources)
  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Nix evaluator and binary cache client for Redox OS";
    mainProgram = "snix";
  };
}
