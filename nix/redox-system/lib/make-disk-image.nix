# Combine partition images into a GPT disk image
#
# Assembles an ESP and RedoxFS partition into a complete bootable disk.
# Each partition is provided as a pre-built raw image file.
#
# Inspired by NixBSD's make-disk-image.nix — a composable disk assembler
# that can be reused independently of the module system.
#
# Usage:
#   mkDiskImage = import ./make-disk-image.nix { inherit hostPkgs lib; };
#   diskImage = mkDiskImage {
#     espImage = espPartition;
#     redoxfsImage = redoxfsPartition;
#     totalSizeMB = 512;
#     espSizeMB = 200;
#     bootloader = pkgs.bootloader;
#     kernel = pkgs.kernel;
#     initfs = initfsDerivation;
#   };
#
# Output: Derivation with redox.img and boot/ directory
{ hostPkgs, lib }:

{
  espImage, # ESP partition image (single file)
  redoxfsImage, # RedoxFS partition image (single file)
  totalSizeMB ? 512,
  espSizeMB ? 200,
  bootloader, # For copying boot files to output
  kernel,
  initfs,
  name ? "redox-disk-image",
}:

hostPkgs.stdenv.mkDerivation {
  pname = name;
  version = "unstable";
  dontUnpack = true;
  dontPatchELF = true;
  dontFixup = true;
  nativeBuildInputs = [ hostPkgs.parted ];
  SOURCE_DATE_EPOCH = "1";
  buildPhase = ''
    runHook preBuild
    IMAGE_SIZE=$((${toString totalSizeMB} * 1024 * 1024))
    ESP_SIZE=$((${toString espSizeMB} * 1024 * 1024))
    ESP_SECTORS=$((ESP_SIZE / 512))
    REDOXFS_START=$((2048 + ESP_SECTORS))

    truncate -s $IMAGE_SIZE disk.img
    parted -s disk.img mklabel gpt
    parted -s disk.img mkpart ESP fat32 1MiB ${toString (espSizeMB + 1)}MiB
    parted -s disk.img set 1 boot on
    parted -s disk.img set 1 esp on
    parted -s disk.img mkpart RedoxFS ${toString (espSizeMB + 1)}MiB 100%

    dd if=${espImage} of=disk.img bs=512 seek=2048 conv=notrunc
    dd if=${redoxfsImage} of=disk.img bs=512 seek=$REDOXFS_START conv=notrunc
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out $out/boot
    cp disk.img $out/redox.img
    cp ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/boot/
    cp ${kernel}/boot/kernel $out/boot/
    cp ${initfs}/boot/initfs $out/boot/
    runHook postInstall
  '';
}
