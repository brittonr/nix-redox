# snix — Nix evaluator and binary cache client for Redox OS
#
# Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
# Cross-compiles to x86_64-unknown-redox with zero platform-specific code.
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
      ;
  };

in
mkUserspace.mkBinary {
  pname = "snix-redox";
  version = "0.1.0";
  src = snix-redox-src;
  binaryName = "snix";

  # Vendor hash — includes git dependency on snix-eval from git.snix.dev
  vendorHash = "sha256-5z6bgOxzGBoP/lKu8xkbxqC19xGnCg4f5p9N+sKwww4=";

  # snix-eval is fetched from git (along with snix-eval-builtin-macros)
  gitSources = [
    {
      url = "git+https://git.snix.dev/snix/snix.git";
      git = "https://git.snix.dev/snix/snix.git";
    }
  ];

  meta = with lib; {
    description = "Nix evaluator and binary cache client for Redox OS";
    mainProgram = "snix";
  };
}
