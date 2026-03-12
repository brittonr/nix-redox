# shellharden - Shell script linter and formatter for Redox OS
#
# shellharden corrects and prevents common shell scripting mistakes.
# Written in pure Rust with no C dependencies.
#
# Source: github.com/anordal/shellharden (upstream, pinned rev)
# Binary: shellharden

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
  shellharden-src,
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
  pname = "shellharden";
  version = "4.3.1";
  src = shellharden-src;
  binaryName = "shellharden";

  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Shell script linter and formatter";
    homepage = "https://github.com/anordal/shellharden";
    license = licenses.mpl20;
    mainProgram = "shellharden";
  };
}
