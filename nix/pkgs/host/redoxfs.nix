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

  src = pkgs.applyPatches {
    inherit src;
    name = "redoxfs-src-patched";
    patches = [
      # Add --uid and --gid options to redoxfs-ar for overriding file ownership
      # This is needed for Nix sandbox builds where files are not owned by root
      ../../patches/redoxfs-uid-gid-override.patch
    ];
  };

  cargoExtraArgs = "--locked";

  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    fuse
    fuse3
  ];

  # Enable unit tests only (integration tests require FUSE mounting which needs sandbox relaxation)
  doCheck = true;
  cargoTestExtraArgs = "--lib";

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
