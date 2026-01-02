# Redox OS disk image builder
{
  lib,
  stdenv,
  runCommand,
  writeShellScript,
  fstools,
  sysroot,
  kernel,
  packages ? [ ],
  configFile ? null,
  filesystemSize ? 650, # MiB
}:
let
  # Build recipe script - invokes cookbook for each package
  buildRecipes = writeShellScript "build-recipes" ''
    set -e
    export PATH="${fstools}/bin:${sysroot}/bin:$PATH"
    export COOKBOOK_HOST_SYSROOT="${sysroot}"
    export TARGET="x86_64-unknown-redox"

    RECIPES_DIR="$1"
    OUTPUT_DIR="$2"

    cd "$RECIPES_DIR"

    # Cook all recipes
    for recipe in ${lib.concatStringsSep " " packages}; do
      echo "Building recipe: $recipe"
      repo cook "$recipe" || true
    done
  '';

in
stdenv.mkDerivation rec {
  pname = "redox-image";
  version = "0.1.0";

  # No source - we build from recipes
  dontUnpack = true;

  nativeBuildInputs = [
    fstools
    sysroot
  ];

  buildPhase = ''
    echo "Building Redox OS disk image..."

    # Create staging area
    mkdir -p staging/boot
    mkdir -p staging/bin
    mkdir -p staging/lib
    mkdir -p staging/etc

    # Copy kernel
    cp ${kernel}/boot/kernel staging/boot/

    # TODO: Build and install base system packages
    # This would invoke cookbook for each required package
  '';

  installPhase = ''
    mkdir -p $out

    # Create the disk image
    truncate -s ${toString filesystemSize}M $out/harddrive.img

    # TODO: Format with redoxfs and install packages
    # This requires FUSE which may not work in sandbox

    echo "Image creation complete (placeholder)"
  '';

  meta = with lib; {
    description = "Redox OS bootable disk image";
    homepage = "https://redox-os.org";
    license = licenses.mit;
  };
}
