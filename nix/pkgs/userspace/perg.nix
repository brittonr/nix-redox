# perg - Parallel grep tool for Redox OS
#
# perg is a parallel grep implementation written in Rust.
# It searches files for patterns using multiple threads.
#
# Source: github.com/guerinoni/perg (upstream, pinned rev for Redox compat)
# Binary: perg

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  perg-src,
  ...
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
  pname = "perg";
  version = "0.6.0";
  src = perg-src;
  binaryName = "perg";

  vendorHash = "sha256-0000000000000000000000000000000000000000000=";

  meta = with lib; {
    description = "Parallel grep tool";
    homepage = "https://github.com/guerinoni/perg";
    license = licenses.mit;
    mainProgram = "perg";
  };
}
