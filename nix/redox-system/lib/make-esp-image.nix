# Create an EFI System Partition image
#
# Produces a raw FAT32 filesystem image containing the UEFI bootloader,
# kernel, and initfs. This is one component of a complete disk image.
#
# Inspired by NixBSD's make-partition-image.nix — a composable partition
# builder that can be reused independently of the module system.
#
# Usage:
#   mkEspImage = import ./make-esp-image.nix { inherit hostPkgs lib; };
#   espImage = mkEspImage {
#     bootloader = pkgs.bootloader;
#     kernel = pkgs.kernel;
#     initfs = initfsDerivation;
#   };
#
# Output: A single-file derivation (the raw ESP image, not a directory)
{ hostPkgs, lib }:

{
  bootloader, # Package with boot/EFI/BOOT/BOOTX64.EFI
  kernel, # Package with boot/kernel
  initfs, # Package with boot/initfs
  sizeMB ? 200,
}:

hostPkgs.runCommand "redox-esp"
  {
    nativeBuildInputs = with hostPkgs; [
      dosfstools
      mtools
    ];
  }
  ''
    SIZE=$((${toString sizeMB} * 1024 * 1024))
    truncate -s $SIZE esp.img
    mkfs.vfat -F 32 -n "EFI" esp.img
    mmd -i esp.img ::EFI ::EFI/BOOT
    mcopy -i esp.img ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI ::EFI/BOOT/
    mcopy -i esp.img ${kernel}/boot/kernel ::EFI/BOOT/kernel
    mcopy -i esp.img ${initfs}/boot/initfs ::EFI/BOOT/initfs
    echo '\EFI\BOOT\BOOTX64.EFI' > startup.nsh
    mcopy -i esp.img startup.nsh ::
    cp esp.img $out
  ''
