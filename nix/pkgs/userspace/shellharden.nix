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
      ;
  };

in
mkUserspace.mkBinary {
  pname = "shellharden";
  version = "4.3.1";
  src = shellharden-src;
  binaryName = "shellharden";

  vendorHash = "sha256-kMY+esMOsQZC979jntcqF35KVJCBuNLXHb0WYOV5YHA=";

  meta = with lib; {
    description = "Shell script linter and formatter";
    homepage = "https://github.com/anordal/shellharden";
    license = licenses.mpl20;
    mainProgram = "shellharden";
  };
}
