# RedoxOS Disk Image Builder
#
# This module builds the complete bootable disk image.
# It replaces the monolithic nix/pkgs/infrastructure/disk-image.nix.
#
# Creates a GPT disk with:
#   - Partition 1: 200MB FAT32 ESP (EFI System Partition)
#     - Contains bootloader (BOOTX64.EFI), kernel, initfs
#   - Partition 2: RedoxFS root filesystem
#     - Contains boot/kernel, boot/initfs (for RedoxFS boot fallback)
#     - Contains everything from system.build.rootTree
#
# Inputs (from config):
#   - system.build.rootTree: Root filesystem tree
#   - system.build.initfs: Initfs image
#   - config.redox.boot.kernel: Kernel package
#   - config.redox.boot.bootloader: Bootloader package
#
# Output:
#   - system.build.diskImage: Bootable disk image

{
  config,
  lib,
  pkgs,
  hostPkgs,
  redoxSystemLib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkIf
    types
    ;

  cfg = config.redox.boot;

  # Disk geometry (512MB total)
  diskSizeMB = 512;
  espSizeMB = 200;

in
{
  config = mkIf (cfg.kernel != null && cfg.bootloader != null) {
    system.build.diskImage = hostPkgs.stdenv.mkDerivation {
      pname = "redox-disk-image";
      version = "unstable";

      dontUnpack = true;
      dontPatchELF = true;
      dontFixup = true;

      nativeBuildInputs = with hostPkgs; [
        parted # GPT partitioning
        mtools # FAT filesystem tools
        dosfstools # mkfs.vfat
        pkgs.redoxfs # redoxfs-ar (host tool for creating RedoxFS images)
      ];

      # Fixed timestamp for reproducible builds
      SOURCE_DATE_EPOCH = "1";

      buildPhase = ''
        runHook preBuild

        echo "=== Building Redox OS Disk Image ==="

        # Calculate disk geometry
        IMAGE_SIZE=$((${toString diskSizeMB} * 1024 * 1024))
        ESP_SIZE=$((${toString espSizeMB} * 1024 * 1024))
        ESP_SECTORS=$((ESP_SIZE / 512))
        REDOXFS_START=$((2048 + ESP_SECTORS))
        REDOXFS_END=$(($(($IMAGE_SIZE / 512)) - 34))
        REDOXFS_SECTORS=$((REDOXFS_END - REDOXFS_START))
        REDOXFS_SIZE=$((REDOXFS_SECTORS * 512))

        echo "Disk geometry:"
        echo "  Total size: ${toString diskSizeMB}MB"
        echo "  ESP size: ${toString espSizeMB}MB"
        echo "  RedoxFS start: sector $REDOXFS_START"

        # Create disk image
        truncate -s $IMAGE_SIZE disk.img

        # Create GPT partition table
        echo "Creating GPT partition table..."
        parted -s disk.img mklabel gpt
        parted -s disk.img mkpart ESP fat32 1MiB ${toString (espSizeMB + 1)}MiB
        parted -s disk.img set 1 boot on
        parted -s disk.img set 1 esp on
        parted -s disk.img mkpart RedoxFS ${toString (espSizeMB + 1)}MiB 100%

        # Create FAT32 ESP
        echo "Creating EFI System Partition..."
        truncate -s $ESP_SIZE esp.img
        mkfs.vfat -F 32 -n "EFI" esp.img

        # Populate ESP with bootloader, kernel, initfs
        echo "Populating ESP..."
        mmd -i esp.img ::EFI
        mmd -i esp.img ::EFI/BOOT
        mcopy -i esp.img ${cfg.bootloader}/boot/EFI/BOOT/BOOTX64.EFI ::EFI/BOOT/
        mcopy -i esp.img ${cfg.kernel}/boot/kernel ::EFI/BOOT/kernel
        mcopy -i esp.img ${config.system.build.initfs}/boot/initfs ::EFI/BOOT/initfs

        # Create startup.nsh for automatic boot
        echo '\EFI\BOOT\BOOTX64.EFI' > startup.nsh
        mcopy -i esp.img startup.nsh ::

        # Copy ESP into disk image
        echo "Writing ESP to disk..."
        dd if=esp.img of=disk.img bs=512 seek=2048 conv=notrunc

        # Create RedoxFS root directory
        echo "Assembling RedoxFS root filesystem..."
        mkdir -p redoxfs-root

        # Copy everything from rootTree
        echo "Copying root filesystem tree..."
        cp -r ${config.system.build.rootTree}/* redoxfs-root/

        # Add boot components to RedoxFS (for RedoxFS boot fallback)
        echo "Adding boot components..."
        mkdir -p redoxfs-root/boot
        cp ${cfg.kernel}/boot/kernel redoxfs-root/boot/kernel
        cp ${config.system.build.initfs}/boot/initfs redoxfs-root/boot/initfs

        # Verify critical files
        echo ""
        echo "=== RedoxFS root verification ==="
        echo "Binaries:"
        ls -l redoxfs-root/bin/ion 2>/dev/null || echo "  WARNING: /bin/ion missing!"
        ls -l redoxfs-root/bin/sh 2>/dev/null || echo "  WARNING: /bin/sh missing!"
        echo "Config files:"
        ls -l redoxfs-root/etc/passwd 2>/dev/null || echo "  WARNING: /etc/passwd missing!"
        ls -l redoxfs-root/etc/init.toml 2>/dev/null || echo "  WARNING: /etc/init.toml missing!"
        echo "Boot components:"
        ls -l redoxfs-root/boot/kernel redoxfs-root/boot/initfs
        echo ""
        echo "Total files: $(find redoxfs-root -type f | wc -l)"
        echo "Total binaries: $(find redoxfs-root/bin -type f 2>/dev/null | wc -l)"

        # Create RedoxFS image
        echo "Creating RedoxFS partition image..."
        truncate -s $REDOXFS_SIZE redoxfs.img
        redoxfs-ar --uid 0 --gid 0 redoxfs.img redoxfs-root

        # Copy RedoxFS into disk image
        echo "Writing RedoxFS to disk..."
        dd if=redoxfs.img of=disk.img bs=512 seek=$REDOXFS_START conv=notrunc

        echo ""
        echo "=== Disk image build complete ==="

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp disk.img $out/redox.img

        # Also provide boot components separately
        mkdir -p $out/boot
        cp ${cfg.bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/boot/
        cp ${cfg.kernel}/boot/kernel $out/boot/
        cp ${config.system.build.initfs}/boot/initfs $out/boot/

        # Add metadata
        cat > $out/README << 'EOF'
        Redox OS Disk Image

        This directory contains:
          redox.img - Complete bootable disk image (${toString diskSizeMB}MB)
          boot/     - Individual boot components

        Usage:
          # Write to USB drive (replace /dev/sdX with your device)
          sudo dd if=redox.img of=/dev/sdX bs=4M status=progress

          # Boot in QEMU
          qemu-system-x86_64 -m 2048 -enable-kvm \
            -bios /path/to/OVMF.fd \
            -drive file=redox.img,format=raw

          # Boot in Cloud Hypervisor
          cloud-hypervisor \
            --firmware /path/to/CLOUDHV.fd \
            --disk path=redox.img \
            --cpus boot=4 \
            --memory size=2048M \
            --serial tty \
            --console off

        Partition layout:
          1. EFI System Partition (${toString espSizeMB}MB FAT32)
             - BOOTX64.EFI (bootloader)
             - kernel (Redox kernel)
             - initfs (initial RAM filesystem)
          2. RedoxFS root partition
             - Complete Redox root filesystem
             - System binaries, libraries, configuration
        EOF

        runHook postInstall
      '';

      meta = with lib; {
        description = "Redox OS bootable disk image";
        license = licenses.mit;
      };
    };
  };
}
