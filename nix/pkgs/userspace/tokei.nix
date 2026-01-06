# tokei - Count your code, quickly
#
# tokei is a program that displays statistics about your code. It shows
# the number of files, total lines within those files and code, comments,
# and blanks grouped by language.
#
# Source: github.com/XAMPPRocky/tokei (upstream, available in Redox pkg repo)
# Binary: tokei
#
# This is a pure Rust application that works well on Redox.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  tokei-src,
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
  pname = "tokei";
  version = "12.1.2";
  src = tokei-src;
  binaryName = "tokei";

  # Vendor hash for tokei dependencies
  # This will need to be computed on first build
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Build tokei with default features
  cargoBuildFlags = "--bin tokei";

  meta = with lib; {
    description = "Count your code, quickly";
    homepage = "https://github.com/XAMPPRocky/tokei";
    license = with licenses; [
      asl20
      mit
    ];
    mainProgram = "tokei";
  };
}
