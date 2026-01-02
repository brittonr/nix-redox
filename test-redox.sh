#!/usr/bin/env bash

# Build the disk image first
echo "Building RedoxOS disk image..."
nix build .#diskImage --option sandbox false || exit 1

# Find OVMF
OVMF=$(ls /nix/store/*/FV/OVMF.fd 2>/dev/null | head -1)
if [ -z "$OVMF" ]; then
  echo "Error: OVMF.fd not found"
  exit 1
fi

# Copy disk image to a writable location
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "Copying disk image to $WORK_DIR..."
if [ -r result/redox.img ]; then
  cp result/redox.img "$WORK_DIR/redox.img"
else
  # If we can't read it as normal user, try with sudo
  echo "Need sudo to copy disk image..."
  sudo cp result/redox.img "$WORK_DIR/redox.img"
  sudo chown $(whoami):$(whoami) "$WORK_DIR/redox.img"
fi
chmod +w "$WORK_DIR/redox.img"

echo "Starting RedoxOS with OVMF at: $OVMF"
echo "Press Enter to select resolution, then the shell will start"
echo "Type 'exit' to quit the shell"
echo ""

# Find the bootloader
BOOTLOADER=$(ls /nix/store/*/boot/EFI/BOOT/BOOTX64.EFI 2>/dev/null | head -1)
if [ -z "$BOOTLOADER" ]; then
  # Try to find it from the result directory
  if [ -f result/boot/BOOTX64.EFI ]; then
    BOOTLOADER="result/boot/BOOTX64.EFI"
  else
    echo "Error: BOOTX64.EFI not found"
    exit 1
  fi
fi

echo "Using bootloader: $BOOTLOADER"

# Run QEMU with the writable disk image
# Note: RedoxOS requires direct kernel boot to work properly
qemu-system-x86_64 \
  -M pc \
  -cpu host \
  -m 2048 \
  -smp 4 \
  -serial mon:stdio \
  -enable-kvm \
  -bios "$OVMF" \
  -kernel "$BOOTLOADER" \
  -drive file="$WORK_DIR/redox.img",format=raw,if=ide \
  -nographic