# difftastic - A structural diff tool for Redox OS
#
# difftastic (difft) is a structural diff tool that compares files
# based on their syntax, not just lines. It understands programming
# languages and produces more meaningful diffs.
#
# Source: github.com/Wilfred/difftastic (upstream)
# Binary: difft
#
# This is a Rust application that should work on Redox.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  difft-src,
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
  pname = "difftastic";
  version = "0.59.0";
  src = difft-src;
  binaryName = "difft";

  # Vendor hash for difftastic dependencies
  # This will need to be computed on first build
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Build difft with default features
  cargoBuildFlags = "--bin difft";

  meta = with lib; {
    description = "A structural diff tool that understands syntax";
    homepage = "https://github.com/Wilfred/difftastic";
    license = licenses.mit;
    mainProgram = "difft";
  };
}
