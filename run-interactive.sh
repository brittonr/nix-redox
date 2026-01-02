#!/usr/bin/env bash

# Build RedoxOS
echo "Building RedoxOS disk image..."
nix build .#diskImage --option sandbox false || exit 1

# Find OVMF
OVMF=$(ls /nix/store/*/FV/OVMF.fd 2>/dev/null | head -1)
if [ -z "$OVMF" ]; then
  echo "Error: OVMF.fd not found"
  exit 1
fi

# Find bootloader
BOOTLOADER=$(ls /nix/store/*/boot/EFI/BOOT/BOOTX64.EFI 2>/dev/null | head -1)
if [ -z "$BOOTLOADER" ]; then
  if [ -f result/boot/BOOTX64.EFI ]; then
    BOOTLOADER="result/boot/BOOTX64.EFI"
  else
    echo "Error: BOOTX64.EFI not found"
    exit 1
  fi
fi

# Copy disk image to writable location
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "Copying disk image..."
cp result/redox.img "$WORK_DIR/redox.img"
chmod +w "$WORK_DIR/redox.img"

echo ""
echo "Starting RedoxOS..."
echo ""
echo "IMPORTANT: The bootloader will auto-select resolution after 3 seconds"
echo "Or press Enter when you see the resolution menu"
echo "After boot, you'll get the 'redox>' prompt"
echo ""
echo "To exit: Press Ctrl+A then X"
echo ""
sleep 2

# Run QEMU with proper stdin handling
exec qemu-system-x86_64 \
  -M pc \
  -cpu host \
  -m 2048 \
  -smp 4 \
  -enable-kvm \
  -bios "$OVMF" \
  -kernel "$BOOTLOADER" \
  -drive file="$WORK_DIR/redox.img",format=raw,if=ide \
  -serial mon:stdio \
  -nographic