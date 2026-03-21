# redb-demo - Embedded key-value database demo for Redox OS
#
# Small binary exercising redb (Rust Embedded DataBase) on Redox.
# Creates a database, writes key-value pairs, reads them back,
# and tests range queries. Proves redb works on Redox's file I/O.
#
# redb uses pread/pwrite via FileExt on unix targets.
# flock() is a no-op on Redox — redb handles this gracefully.
#
# Source: src/redb-demo/ in this repo
# Binary: redb-demo

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
  pname = "redb-demo";
  version = "0.1.0";
  src = ../../../src/redb-demo;
  binaryName = "redb-demo";

  vendorHash = "sha256-Yq24PojBOSDMuGdNpsozfPnm4DeyQxrd2sv3gmci75A=";

  meta = with lib; {
    description = "Embedded key-value database demo (redb) for Redox OS";
    homepage = "https://github.com/cberner/redb";
    license = licenses.mit;
    mainProgram = "redb-demo";
  };
}
