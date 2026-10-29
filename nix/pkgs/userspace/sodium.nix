# Sodium - vi-like text editor for Redox OS
#
# Upstream has no lockfile. Keep a committed dependency graph and use its
# declared orbclient 0.3 dependency rather than a path to a newer API series.
{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  sodium-src,
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

  srcWithLock = pkgs.runCommand "sodium-src-with-lock" { } ''
    cp -r ${sodium-src} $out
    chmod -R u+w $out
    cp ${./sodium-Cargo.lock} $out/Cargo.lock
  '';
in
mkUserspace.mkBinary {
  pname = "sodium";
  version = "0.1.0";
  src = srcWithLock;
  binaryName = "sodium";
  cargoBuildFlags = "--no-default-features --features ansi";

  vendorHash = "sha256-eGtdkMoJcUBj5q+MiNvvtiZDX/jZrRzOaEr2Ziteaps=";

  meta = with lib; {
    description = "Sodium: A vi-like text editor for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/sodium";
    license = licenses.mit;
    mainProgram = "sodium";
  };
}
