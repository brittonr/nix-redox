# tokei - Count lines of code quickly for Redox OS
#
# tokei counts code, comments, and blanks in source files, supporting
# over 150 languages. Written in Rust with zero C dependencies.
#
# Source: github.com/XAMPPRocky/tokei (upstream)
# Binary: tokei

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
  tokei-src,
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
  pname = "tokei";
  version = "14.0.0";
  src = tokei-src;
  binaryName = "tokei";

  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Count lines of code quickly";
    homepage = "https://github.com/XAMPPRocky/tokei";
    license = with licenses; [
      asl20
      mit
    ];
    mainProgram = "tokei";
  };
}
