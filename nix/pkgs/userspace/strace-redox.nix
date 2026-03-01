# strace-redox - System call tracer for Redox OS
#
# A Rust implementation of strace for Redox OS. Traces system calls
# and signals for debugging.
#
# Source: gitlab.redox-os.org/redox-os/strace-redox (Redox-native)
# Binary: strace

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  strace-redox-src,
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
  pname = "strace-redox";
  src = strace-redox-src;
  binaryName = "strace";

  vendorHash = "sha256-mz5MtGbCxzaQ2pmP5oswxJcUi7l8agSkD/wikkl3g/M=";

  meta = with lib; {
    description = "System call tracer for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/strace-redox";
    license = licenses.mit;
    mainProgram = "strace";
  };
}
