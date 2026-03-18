# gdbstub - GDB remote debugging stub for Redox OS
#
# Translates GDB RSP commands into Redox proc: scheme operations.
# Supports attach-by-PID and launch-and-debug.
# Dependencies: gdb-protocol, redox_syscall, libc
#
# Source: src/gdbstub/ in this repo

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
mkUserspace.mkPackage {
  pname = "gdbstub";
  src = ../../../src/gdbstub;
  vendorHash = "sha256-8FpgCbA4IifAKZs8muw9AcvmgCdVbCN1y8KFm3Nw1rQ=";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/gdbstub $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "GDB remote debugging stub for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/";
    license = licenses.mit;
    mainProgram = "gdbstub";
  };
}
