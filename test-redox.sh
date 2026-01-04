#!/usr/bin/env bash

# Build and run RedoxOS for testing
set -euo pipefail

# Build the disk image first
echo "Building RedoxOS disk image..."
nix build .#diskImage || exit 1

# Discover OVMF from nix store
OVMF=$(find /nix/store -maxdepth 2 -name "OVMF.fd" -path "*/FV/*" 2>/dev/null | head -1)
if [ -z "$OVMF" ]; then
  echo "Error: OVMF.fd not found in nix store"
  echo "Hint: Enter a nix shell with 'nix develop' first"
  exit 1
fi

# Copy disk image to a writable location
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Copying disk image to $WORK_DIR..."
cp result/redox.img "$WORK_DIR/redox.img"
chmod +w "$WORK_DIR/redox.img"

echo "Starting RedoxOS with OVMF at: $OVMF"
echo "Press Enter to select resolution, then the shell will start"
echo "Type 'exit' to quit the shell"
echo ""

# Find the bootloader from result
BOOTLOADER=""
if [ -L result ]; then
  BOOTLOADER=$(find "$(readlink -f result)" -name "BOOTX64.EFI" 2>/dev/null | head -1)
fi
if [ -z "$BOOTLOADER" ] && [ -f result/boot/EFI/BOOT/BOOTX64.EFI ]; then
  BOOTLOADER="result/boot/EFI/BOOT/BOOTX64.EFI"
fi

if [ -z "$BOOTLOADER" ]; then
  echo "Error: BOOTX64.EFI not found in build output"
  exit 1
fi

echo "Using bootloader: $BOOTLOADER"

# Run QEMU with the writable disk image
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
