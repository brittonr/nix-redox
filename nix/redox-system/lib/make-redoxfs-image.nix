# Create a RedoxFS partition image
#
# Produces a raw RedoxFS filesystem image from a root tree, with kernel
# and initfs copied into /boot. This is one component of a complete disk image.
#
# Inspired by NixBSD's make-partition-image.nix — a composable partition
# builder that can be reused independently of the module system.
#
# Usage:
#   mkRedoxfsImage = import ./make-redoxfs-image.nix { inherit hostPkgs lib; };
#   redoxfsImage = mkRedoxfsImage {
#     redoxfs = pkgs.redoxfs;
#     rootTree = rootTreeDerivation;
#     kernel = pkgs.kernel;
#     initfs = initfsDerivation;
#   };
#
# Output: A single-file derivation (the raw RedoxFS image, not a directory)
{ hostPkgs, lib }:

{
  redoxfs, # The redoxfs host tool package (provides redoxfs-ar)
  rootTree, # The root filesystem tree derivation
  kernel, # Kernel package with boot/kernel
  initfs, # Initfs package with boot/initfs
}:

hostPkgs.runCommand "redox-redoxfs"
  {
    nativeBuildInputs = [ redoxfs ];
  }
  ''
    mkdir -p root
    cp -r ${rootTree}/* root/
    mkdir -p root/boot
    cp ${kernel}/boot/kernel root/boot/kernel
    cp ${initfs}/boot/initfs root/boot/initfs
    redoxfs-ar --uid 0 --gid 0 redoxfs.img root
    cp redoxfs.img $out
  ''
