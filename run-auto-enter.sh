#!/usr/bin/env bash

# Build and run RedoxOS with automatic resolution selection
set -e

# Build RedoxOS
echo "Building RedoxOS disk image..."
nix build .#diskImage || exit 1

# Discover OVMF from nix store
OVMF=$(find /nix/store -maxdepth 2 -name "OVMF.fd" -path "*/FV/*" 2>/dev/null | head -1)
if [ -z "$OVMF" ]; then
  echo "Error: OVMF.fd not found in nix store"
  echo "Hint: Enter a nix shell with 'nix develop' first"
  exit 1
fi

# Find bootloader from result
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

# Copy disk image to writable location
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "Copying disk image..."
cp result/redox.img "$WORK_DIR/redox.img"
chmod +w "$WORK_DIR/redox.img"

echo ""
echo "Starting RedoxOS with automatic resolution selection..."
echo "Will send Enter after 4 seconds to select default resolution"
echo ""

# Create a named pipe for input
FIFO=$(mktemp -u)
mkfifo "$FIFO"

# Send Enter after a delay in the background
(
  sleep 4
  echo ""
  echo "Sent Enter key to select resolution"
) >"$FIFO" &

# Run QEMU with input from the FIFO
qemu-system-x86_64 \
  -M pc \
  -cpu host \
  -m 2048 \
  -smp 4 \
  -enable-kvm \
  -bios "$OVMF" \
  -kernel "$BOOTLOADER" \
  -drive file="$WORK_DIR/redox.img",format=raw,if=ide \
  -serial mon:stdio \
  -nographic <"$FIFO"

# Clean up
rm -f "$FIFO"
