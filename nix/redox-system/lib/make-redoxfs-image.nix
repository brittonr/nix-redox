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
  redoxfs, # The redoxfs host tool package (provides redoxfs-ar, redoxfs-mkfs)
  rootTree, # The root filesystem tree derivation
  kernel, # Kernel package with boot/kernel
  initfs, # Initfs package with boot/initfs
  bootloader ? null, # Bootloader package with boot/EFI/BOOT/BOOTX64.EFI
  sizeMB ? 308, # Size in MB (default: 512 - 200 ESP - 4 GPT overhead)
  # Per-path ownership overrides for redoxfs-ar.
  # List of { path, uid, gid } where path is relative to root (e.g. "home/user").
  ownershipMap ? [ ],
}:

let
  chownArgs = lib.concatMapStringsSep " " (
    entry: "--chown ${entry.path}:${toString entry.uid}:${toString entry.gid}"
  ) ownershipMap;
in
hostPkgs.runCommand "redox-redoxfs"
  {
    nativeBuildInputs = [ redoxfs ];
  }
  ''
    mkdir -p root
    cp -r ${rootTree}/* root/
    chmod -R u+w root/

    # /tmp must be world-writable with sticky bit (like any Unix system)
    chmod 1777 root/tmp

    # Install boot components as store paths (for generation tracking)
    # These are the authoritative copies — /boot/ files are for bootloader compat.
    kernelStore="root/nix/store/${builtins.baseNameOf (toString kernel)}"
    mkdir -p "$kernelStore/boot"
    cp ${kernel}/boot/kernel "$kernelStore/boot/kernel"

    initfsStore="root/nix/store/${builtins.baseNameOf (toString initfs)}"
    mkdir -p "$initfsStore/boot"
    cp ${initfs}/boot/initfs "$initfsStore/boot/initfs"

    ${lib.optionalString (bootloader != null) ''
      blStore="root/nix/store/${builtins.baseNameOf (toString bootloader)}"
      mkdir -p "$blStore/boot/EFI/BOOT"
      cp ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI "$blStore/boot/EFI/BOOT/BOOTX64.EFI"
    ''}

    # /boot/ copies for bootloader compatibility (reads from RedoxFS /boot/)
    mkdir -p root/boot
    cp ${kernel}/boot/kernel root/boot/kernel
    cp ${initfs}/boot/initfs root/boot/initfs

    # Pre-allocate the image file — redoxfs-ar requires it to exist
    dd if=/dev/zero of=redoxfs.img bs=1M count=${toString sizeMB} 2>/dev/null

    # Populate with RedoxFS (formats and archives in one step)
    # --uid 0 --gid 0: default everything to root ownership
    # --chown path:uid:gid: per-path overrides for user home directories
    redoxfs-ar --uid 0 --gid 0 ${chownArgs} redoxfs.img root
    cp redoxfs.img $out
  ''
