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
  nativeBuildInputs = [ hostPkgs.parted hostPkgs.python3 ];
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

    ${hostPkgs.python3}/bin/python3 - <<'PY'
    import binascii
    import hashlib
    import os
    import struct
    import uuid

    SECTOR_SIZE = 512
    ENTRY_GUID_OFFSET = 16

    def guid_le(seed: str) -> bytes:
        raw = bytearray(hashlib.sha256(seed.encode()).digest()[:16])
        raw[6] = (raw[6] & 0x0F) | 0x40
        raw[8] = (raw[8] & 0x3F) | 0x80
        return uuid.UUID(bytes=bytes(raw)).bytes_le

    def read_at(handle, offset: int, size: int) -> bytearray:
        handle.seek(offset)
        return bytearray(handle.read(size))

    def write_at(handle, offset: int, data: bytes) -> None:
        handle.seek(offset)
        handle.write(data)

    disk_seed = "disk:${toString totalSizeMB}:${toString espSizeMB}:${toString espImage}:${toString redoxfsImage}"
    esp_seed = "esp:${toString totalSizeMB}:${toString espSizeMB}:${toString espImage}"
    redoxfs_seed = "redoxfs:${toString totalSizeMB}:${toString espSizeMB}:${toString redoxfsImage}"

    with open("disk.img", "r+b") as f:
        image_size = os.fstat(f.fileno()).st_size
        last_lba = image_size // SECTOR_SIZE - 1

        primary_header_offset = SECTOR_SIZE
        backup_header_offset = last_lba * SECTOR_SIZE
        primary_header = read_at(f, primary_header_offset, SECTOR_SIZE)
        backup_header = read_at(f, backup_header_offset, SECTOR_SIZE)

        header_size = struct.unpack_from("<I", primary_header, 12)[0]
        primary_entries_lba = struct.unpack_from("<Q", primary_header, 72)[0]
        backup_entries_lba = struct.unpack_from("<Q", backup_header, 72)[0]
        entry_count = struct.unpack_from("<I", primary_header, 80)[0]
        entry_size = struct.unpack_from("<I", primary_header, 84)[0]
        entries_size = entry_count * entry_size

        primary_entries_offset = primary_entries_lba * SECTOR_SIZE
        backup_entries_offset = backup_entries_lba * SECTOR_SIZE
        primary_entries = read_at(f, primary_entries_offset, entries_size)
        backup_entries = read_at(f, backup_entries_offset, entries_size)

        disk_guid = guid_le(disk_seed)
        primary_header[56:72] = disk_guid
        backup_header[56:72] = disk_guid

        for index, seed in enumerate((esp_seed, redoxfs_seed)):
            guid = guid_le(seed)
            offset = index * entry_size + ENTRY_GUID_OFFSET
            primary_entries[offset:offset + 16] = guid
            backup_entries[offset:offset + 16] = guid

        write_at(f, primary_entries_offset, primary_entries)
        write_at(f, backup_entries_offset, backup_entries)

        entries_crc = binascii.crc32(primary_entries) & 0xFFFFFFFF
        struct.pack_into("<I", primary_header, 88, entries_crc)
        struct.pack_into("<I", backup_header, 88, entries_crc)

        struct.pack_into("<I", primary_header, 16, 0)
        primary_crc = binascii.crc32(primary_header[:header_size]) & 0xFFFFFFFF
        struct.pack_into("<I", primary_header, 16, primary_crc)

        struct.pack_into("<I", backup_header, 16, 0)
        backup_crc = binascii.crc32(backup_header[:header_size]) & 0xFFFFFFFF
        struct.pack_into("<I", backup_header, 16, backup_crc)

        write_at(f, primary_header_offset, primary_header)
        write_at(f, backup_header_offset, backup_header)
    PY

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
