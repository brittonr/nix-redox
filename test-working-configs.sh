#!/bin/bash

# Test script for working QEMU configurations with RedoxOS using direct kernel boot
set -euo pipefail

# Configuration
DISK_IMAGE="${DISK_IMAGE:-/tmp/redox-test.img}"
TEST_DIR="/tmp/qemu-redox-working-tests"
TIMEOUT=25

# Discover OVMF from nix store
OVMF_FD=$(find /nix/store -maxdepth 2 -name "OVMF.fd" -path "*/FV/*" 2>/dev/null | head -1)
if [ -z "$OVMF_FD" ]; then
  echo "Error: OVMF.fd not found in nix store"
  echo "Hint: Enter a nix shell with 'nix develop' first"
  exit 1
fi
OVMF_DIR=$(dirname "$OVMF_FD")
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS="/tmp/OVMF_VARS_test.fd"

# Use system qemu or find from nix store
QEMU=$(command -v qemu-system-x86_64 2>/dev/null || find /nix/store -maxdepth 3 -name "qemu-system-x86_64" -type f 2>/dev/null | head -1)
if [ -z "$QEMU" ]; then
  echo "Error: qemu-system-x86_64 not found"
  exit 1
fi

# Find bootloader from disk image build output or nix store
BOOTLOADER=""
if [ -f result/boot/EFI/BOOT/BOOTX64.EFI ]; then
  BOOTLOADER="result/boot/EFI/BOOT/BOOTX64.EFI"
elif [ -L result ]; then
  BOOTLOADER=$(find "$(readlink -f result)" -name "BOOTX64.EFI" 2>/dev/null | head -1)
fi
if [ -z "$BOOTLOADER" ]; then
  # Try temp location as fallback
  BOOTLOADER="/tmp/bootx64-redox.efi"
  if [ ! -f "$BOOTLOADER" ]; then
    echo "Warning: BOOTX64.EFI not found, tests requiring bootloader will skip"
    BOOTLOADER=""
  fi
fi

# Check if disk image exists
if [[ ! -f $DISK_IMAGE ]]; then
  echo "Error: Disk image not found at $DISK_IMAGE"
  echo "Build it with: nix build .#diskImage && cp result/redox.img $DISK_IMAGE"
  exit 1
fi

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Create writable OVMF_VARS copy
if [ -f "$OVMF_DIR/OVMF_VARS.fd" ]; then
  cp "$OVMF_DIR/OVMF_VARS.fd" "$OVMF_VARS" 2>/dev/null || true
  chmod 644 "$OVMF_VARS" 2>/dev/null || true
fi

# Function to run QEMU test with timeout
run_qemu_test() {
  local test_name="$1"
  shift
  local qemu_args="$@"

  echo "===== Testing: $test_name ====="

  local log_file="$TEST_DIR/${test_name}.log"

  # Run QEMU with timeout and expect resolution selection
  (timeout $TIMEOUT "$QEMU" \
    -m 2048 \
    -smp 2 \
    -enable-kvm \
    ${BOOTLOADER:+-kernel "$BOOTLOADER"} \
    -serial file:"$log_file" \
    -monitor none \
    -display none \
    -device isa-debug-exit \
    $qemu_args \
    2>&1 || true) | head -15

  # Check log for boot success indicators
  echo ""
  echo "--- Boot results ---"
  if grep -q "RedoxFS.*MiB" "$log_file" 2>/dev/null; then
    echo "SUCCESS: RedoxFS filesystem detected"
    if grep -q "Output.*resolution" "$log_file" 2>/dev/null; then
      echo "SUCCESS: Display resolution menu shown"
    fi
  elif grep -q "Redox OS Bootloader" "$log_file" 2>/dev/null; then
    echo "PARTIAL: Bootloader started but filesystem issues"
  else
    echo "FAILED: Bootloader did not start"
  fi

  echo ""
  sleep 2
}

echo "=== TESTING WORKING QEMU CONFIGS FOR REDOX ==="
echo "OVMF: $OVMF_FD"
echo "QEMU: $QEMU"
echo "Bootloader: ${BOOTLOADER:-none}"
echo "Using direct kernel boot method"
echo ""

# Test 1: Original configuration - IDE interface, pc machine
run_qemu_test "ide-pc-machine" \
  -M pc \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=ide

# Test 2: AHCI interface (SATA) with q35
run_qemu_test "ahci-q35-machine" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device ahci,id=ahci0 \
  -device ide-hd,drive=disk0,bus=ahci0.0

# Test 3: VirtIO block device with q35
run_qemu_test "virtio-blk-q35" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0

# Test 4: VirtIO block device with pc machine
run_qemu_test "virtio-blk-pc" \
  -M pc \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0

# Test 5: NVME interface with q35
run_qemu_test "nvme-q35" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device nvme,serial=deadbeef,drive=disk0

# Test 6: SCSI interface
run_qemu_test "scsi-pc" \
  -M pc \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device virtio-scsi-pci \
  -device scsi-hd,drive=disk0

# Test 7: Using OVMF_CODE.fd + OVMF_VARS.fd (proper UEFI setup)
if [ -f "$OVMF_VARS" ]; then
  run_qemu_test "ovmf-code-vars-setup" \
    -M q35 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$DISK_IMAGE",format=raw,if=ide
fi

echo "=== SUMMARY ==="
echo "All tests completed. Successful configurations will show 'RedoxFS' detection."
echo "Logs available in: $TEST_DIR"
