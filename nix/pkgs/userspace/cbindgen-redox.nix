# cbindgen - C header generator for Rust libraries on Redox OS
#
# Cross-compiles Mozilla's cbindgen (same version/source as host
# pkgs.rust-cbindgen) to x86_64-unknown-redox so the guest can generate
# relibc C headers identically to host builds.
#
# Binary: cbindgen

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
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
  pname = "redox-cbindgen";
  version = pkgs.rust-cbindgen.version;
  src = pkgs.rust-cbindgen.src;
  binaryName = "cbindgen";

  vendorHash = "sha256-DbmlpjiOraLWPh5RgJqCIGIYzE1h82MH2S6gpLH+CIQ=";

  meta = with lib; {
    description = "Tool for generating C bindings to Rust code for Redox OS";
    homepage = "https://github.com/mozilla/cbindgen";
    license = licenses.mpl20;
    mainProgram = "cbindgen";
  };
}
