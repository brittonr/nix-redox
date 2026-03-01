# lsd - Modern ls replacement for Redox OS
#
# lsd (LSDeluxe) is a modern replacement for ls with colors, icons, and
# tree display. Written in Rust.
#
# Source: github.com/lsd-rs/lsd (upstream)
# Binary: lsd

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  lsd-src,
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
  pname = "lsd";
  version = "1.2.0";
  src = lsd-src;
  binaryName = "lsd";

  vendorHash = "sha256-TcC8ZY8Xv0076bLrprXGPh5nyGnR2NRnGeuTSEK4+Gg=";

  # Disable default features that may need Unix-specific functionality
  cargoBuildFlags = "--bin lsd --no-default-features";

  meta = with lib; {
    description = "Modern ls replacement with colors and icons";
    homepage = "https://github.com/lsd-rs/lsd";
    license = licenses.asl20;
    mainProgram = "lsd";
  };
}
