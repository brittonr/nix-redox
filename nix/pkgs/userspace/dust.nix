# dust - A more intuitive version of du for Redox OS
#
# dust is a more intuitive version of du. It displays directories
# and files in a visual hierarchy, making it easier to understand
# disk space usage at a glance.
#
# Source: github.com/bootandy/dust (upstream)
# Binary: dust
#
# This is a pure Rust application that should cross-compile well to Redox.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  dust-src,
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
  pname = "dust";
  version = "1.0.0";
  src = dust-src;
  binaryName = "dust";

  # Vendor hash for dust dependencies
  # This will need to be computed on first build
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Build dust with default features
  cargoBuildFlags = "--bin dust";

  meta = with lib; {
    description = "A more intuitive version of du in Rust";
    homepage = "https://github.com/bootandy/dust";
    license = licenses.asl20;
    mainProgram = "dust";
  };
}
