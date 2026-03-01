# bottom - Graphical system/process monitor for Redox OS
#
# A cross-platform graphical process/system monitor with a customizable
# interface and a multitude of features. Uses jackpot51's Redox fork.
#
# Source: github.com/jackpot51/bottom (Redox fork)
# Binary: btm

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  bottom-src,
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
  pname = "bottom";
  version = "unstable";
  src = bottom-src;
  binaryName = "btm";

  vendorHash = "sha256-xvG6CMgOHxSjJ+/B+NEqULK+f2V/BWlwh0YBGXeC4J0=";

  gitSources = [
    {
      url = "git+https://github.com/jackpot51/sysinfo.git";
      git = "https://github.com/jackpot51/sysinfo.git";
    }
  ];

  meta = with lib; {
    description = "Graphical process/system monitor";
    homepage = "https://github.com/ClementTsang/bottom";
    license = licenses.mit;
    mainProgram = "btm";
  };
}
