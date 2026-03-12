# smith - Text editor for Redox OS
#
# Smith is a simple text editor written in Rust, originally built for
# Redox OS. It has a vi-inspired modal interface.
#
# Source: gitlab.redox-os.org/redox-os/Smith (Redox-native)
# Binary: smith

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
  smith-src,
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
      unit2nixVendor
      ;
  };

in
mkUserspace.mkBinary {
  pname = "smith";
  src = smith-src;
  binaryName = "smith";

  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Simple text editor for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/Smith";
    license = licenses.mit;
    mainProgram = "smith";
  };
}
