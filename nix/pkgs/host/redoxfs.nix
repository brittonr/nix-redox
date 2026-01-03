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
    description = "Redox Filesystem tools for creating and managing RedoxFS images";
    longDescription = ''
      RedoxFS is the filesystem used by Redox OS. This package provides host
      tools for creating, mounting, and manipulating RedoxFS filesystem images.
    '';
    homepage = "https://gitlab.redox-os.org/redox-os/redoxfs";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "redoxfs";
  };
}
