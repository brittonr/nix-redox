# Cookbook - Redox package build system (host tool)
#
# This is the package manager and build system for Redox OS.
# It runs on the host machine (not cross-compiled).

{
  pkgs,
  lib,
  craneLib,
  src,
  ...
}:

craneLib.buildPackage {
  pname = "redox-cookbook";
  version = "0.1.0";

  inherit src;

  cargoExtraArgs = "--locked";

  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    openssl
    fuse
  ];

  doCheck = false;

  meta = with lib; {
    description = "Redox OS Cookbook - package build system";
    homepage = "https://gitlab.redox-os.org/redox-os/redox";
    license = licenses.mit;
  };
}
