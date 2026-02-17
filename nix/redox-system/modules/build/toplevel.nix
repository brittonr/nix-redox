# RedoxOS Build Toplevel
#
# Declares the system.build namespace and creates the toplevel output.
# This is the entry point for all build products.
#
# The system.build namespace is where all build modules contribute their
# derivations (rootTree, initfs, diskImage, etc.). This module declares
# the namespace with a loose type to allow any build product.
#
# Pattern: lazyAttrsOf raw (same as NixOS system.build)
# This allows other modules to set system.build.rootTree, system.build.initfs,
# system.build.diskImage without type conflicts.

{
  config,
  lib,
  pkgs,
  hostPkgs,
  ...
}:

let
  inherit (lib) mkOption types;

in
{
  # Declare system.build as a lazy attrset that accepts any value.
  # Other modules (activation.nix, initfs.nix, disk-image.nix) contribute
  # their derivations here.
  options.system.build = mkOption {
    type = types.lazyAttrsOf types.raw;
    default = { };
    description = ''
      Attribute set of build products for the Redox system.

      Build modules contribute derivations here:
        - system.build.rootTree: Root filesystem tree (from activation.nix)
        - system.build.initfs: Initial RAM filesystem (from build/initfs.nix)
        - system.build.diskImage: Bootable disk image (from build/disk-image.nix)
        - system.build.toplevel: Final combined output (this module)

      Using lazyAttrsOf allows modules to contribute any derivation without
      type conflicts. The evaluation is lazy to allow cross-references.
    '';
  };

  # Toplevel is a convenience that combines all main build products
  config.system.build.toplevel = hostPkgs.symlinkJoin {
    name = "redox-system";
    paths = [
      config.system.build.diskImage
      config.system.build.initfs
      config.system.build.rootTree
    ];
    postBuild = ''
      echo "Redox OS System" > $out/README
      echo "Built with redox-system module system" >> $out/README
      echo "" >> $out/README
      echo "Contents:" >> $out/README
      echo "  redox.img - Bootable disk image" >> $out/README
      echo "  boot/initfs - Initial RAM filesystem" >> $out/README
      echo "  boot/kernel - Kernel image" >> $out/README
      echo "  boot/BOOTX64.EFI - UEFI bootloader" >> $out/README
    '';
  };
}
