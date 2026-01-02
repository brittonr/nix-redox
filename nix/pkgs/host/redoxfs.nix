# RedoxFS - Redox filesystem tools (host tool)
#
# Provides tools for creating and manipulating RedoxFS filesystems.
# Runs on the host machine (not cross-compiled).

{
  pkgs,
  lib,
  craneLib,
  src,
  ...
}:

craneLib.buildPackage {
  pname = "redoxfs";
  version = "unstable";

  inherit src;

  cargoExtraArgs = "--locked";

  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    fuse
    fuse3
  ];

  doCheck = false;

  meta = with lib; {
    description = "Redox Filesystem";
    homepage = "https://gitlab.redox-os.org/redox-os/redoxfs";
    license = licenses.mit;
  };
}
