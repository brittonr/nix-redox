#!/bin/bash

# Comprehensive QEMU test for RedoxOS UEFI configurations
set -e

# Configuration
DISK_IMAGE="${DISK_IMAGE:-/tmp/redox-test.img}"
TEST_DIR="/tmp/qemu-redox-tests"
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
OVMF_VARS="$OVMF_DIR/OVMF_VARS.fd"

# Use system qemu or find from nix store
QEMU=$(command -v qemu-system-x86_64 2>/dev/null || find /nix/store -maxdepth 3 -name "qemu-system-x86_64" -type f 2>/dev/null | head -1)
if [ -z "$QEMU" ]; then
  echo "Error: qemu-system-x86_64 not found"
  exit 1
fi

# Find bootloader from disk image build output
BOOTLOADER=""
if [ -f result/boot/EFI/BOOT/BOOTX64.EFI ]; then
  BOOTLOADER="result/boot/EFI/BOOT/BOOTX64.EFI"
elif [ -L result ]; then
  BOOTLOADER=$(find "$(readlink -f result)" -name "BOOTX64.EFI" 2>/dev/null | head -1)
fi
if [ -z "$BOOTLOADER" ]; then
  # Try nix store as fallback
  BOOTLOADER=$(find /nix/store -maxdepth 4 -name "BOOTX64.EFI" -path "*redox*" 2>/dev/null | head -1)
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

# Create writable OVMF_VARS copy for tests that need it
cp "$OVMF_VARS" /tmp/OVMF_VARS_test.fd 2>/dev/null || true
chmod 644 /tmp/OVMF_VARS_test.fd 2>/dev/null || true

# Function to run QEMU test with timeout
run_qemu_test() {
  local test_name="$1"
  shift
  local qemu_args="$@"

  echo "===== Testing: $test_name ====="
  echo "Args: $qemu_args"
  echo ""

  local log_file="$TEST_DIR/${test_name}.log"

  # Run QEMU with timeout, capture both stdout and stderr
  (timeout $TIMEOUT "$QEMU" \
    -m 2048 \
    -smp 2 \
    -enable-kvm \
    -serial file:"$log_file" \
    -monitor none \
    -display none \
    -device isa-debug-exit \
    $qemu_args \
    2>&1 || true) | head -10

  # Check log for boot success indicators
  echo "--- Boot log (first 20 lines) ---"
  head -20 "$log_file" 2>/dev/null || echo "No log output"
  echo ""

  if grep -qi "redox.*boot.*complete\|login:" "$log_file" 2>/dev/null; then
    echo "SUCCESS: Boot completed"
  elif grep -qi "redox\|kernel\|bootloader" "$log_file" 2>/dev/null; then
    echo "PARTIAL: Some RedoxOS boot progress"
  elif grep -qi "uefi\|bds" "$log_file" 2>/dev/null; then
    echo "FIRMWARE: UEFI running but no OS boot"
  else
    echo "FAILED: No recognizable boot activity"
  fi
  echo ""
  sleep 2
}

echo "=== COMPREHENSIVE QEMU REDOX BOOT TESTS ==="
echo "OVMF: $OVMF_FD"
echo "QEMU: $QEMU"
echo "Disk image: $DISK_IMAGE"
echo "Bootloader: $BOOTLOADER"
echo "Test directory: $TEST_DIR"
echo ""

# Test 1: Original flake configuration (with direct kernel boot)
if [ -n "$BOOTLOADER" ]; then
  run_qemu_test "original-flake-style" \
    -M pc \
    -bios "$OVMF_FD" \
    -kernel "$BOOTLOADER" \
    -drive file="$DISK_IMAGE",format=raw,if=ide
fi

# Test 2: Direct disk boot with IDE interface
run_qemu_test "ide-disk-boot" \
  -M pc \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=ide

# Test 3: AHCI interface (SATA)
run_qemu_test "ahci-disk-boot" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device ahci,id=ahci0 \
  -device ide-hd,drive=disk0,bus=ahci0.0

# Test 4: VirtIO block device
run_qemu_test "virtio-blk-boot" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0

# Test 5: NVME interface
run_qemu_test "nvme-boot" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
  -device nvme,serial=deadbeef,drive=disk0

# Test 6: Using OVMF_CODE.fd instead of OVMF.fd
if [ -f /tmp/OVMF_VARS_test.fd ]; then
  run_qemu_test "ovmf-code-vars" \
    -M q35 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file=/tmp/OVMF_VARS_test.fd \
    -drive file="$DISK_IMAGE",format=raw,if=ide
fi

# Test 7: Explicit boot order
run_qemu_test "explicit-boot-order" \
  -M pc \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=ide,bootindex=1 \
  -boot order=c

echo "All tests completed. Logs available in $TEST_DIR"
