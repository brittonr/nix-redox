# onefetch - Git repository summary for Redox OS
#
# A command-line Git information tool that displays repository information
# and code statistics. Written in Rust.
#
# Source: github.com/o2sh/onefetch (upstream)
# Binary: onefetch

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
  onefetch-src,
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
  pname = "onefetch";
  version = "2.13.2";
  src = onefetch-src;
  binaryName = "onefetch";

  # Dummy hash — will be replaced after first build attempt
  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Git repository summary tool";
    homepage = "https://github.com/o2sh/onefetch";
    license = licenses.mit;
    mainProgram = "onefetch";
  };
}
