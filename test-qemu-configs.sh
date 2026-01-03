#!/bin/bash

# Test script for different QEMU configurations with RedoxOS UEFI image
set -e

# Configuration
DISK_IMAGE="${DISK_IMAGE:-/tmp/redox-test.img}"
TEST_DIR="/tmp/qemu-redox-tests"
TIMEOUT=30

# Discover OVMF from nix store (same pattern as run-*.sh scripts)
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

# Check if disk image exists
if [[ ! -f $DISK_IMAGE ]]; then
  echo "Error: Disk image not found at $DISK_IMAGE"
  echo "Build it with: nix build .#diskImage && cp result/redox.img $DISK_IMAGE"
  exit 1
fi

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Function to run QEMU test with timeout
run_qemu_test() {
  local test_name="$1"
  shift
  local qemu_args="$@"

  echo "===== Testing: $test_name ====="
  echo "Command: $QEMU $qemu_args"
  echo ""

  local log_file="$TEST_DIR/${test_name}.log"

  # Run QEMU with timeout
  timeout $TIMEOUT "$QEMU" \
    -m 2048 \
    -smp 2 \
    -enable-kvm \
    -serial file:"$log_file" \
    -monitor none \
    -display none \
    -device isa-debug-exit \
    $qemu_args \
    2>&1 | head -20 || true

  # Check log for boot success indicators
  echo "--- Log output (first 30 lines) ---"
  head -30 "$log_file" 2>/dev/null || echo "No log output"
  echo ""

  if grep -q "Redox OS boot complete\|login:" "$log_file" 2>/dev/null; then
    echo "SUCCESS: Boot appears successful"
  elif grep -q "UEFI\|RedoxFS\|kernel" "$log_file" 2>/dev/null; then
    echo "PARTIAL: Some boot progress detected"
  else
    echo "FAILED: No boot progress detected"
  fi
  echo ""
  sleep 2
}

echo "Starting QEMU configuration tests for RedoxOS UEFI boot"
echo "OVMF: $OVMF_FD"
echo "QEMU: $QEMU"
echo "Disk image: $DISK_IMAGE"
echo "Test directory: $TEST_DIR"
echo ""

# Test 1: Current configuration (IDE, pc machine, OVMF.fd)
run_qemu_test "ide-pc-ovmf" \
  -M pc \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=ide

# Test 2: IDE with q35 machine
run_qemu_test "ide-q35-ovmf" \
  -M q35 \
  -bios "$OVMF_FD" \
  -drive file="$DISK_IMAGE",format=raw,if=ide

echo "Initial IDE tests completed. Check logs in $TEST_DIR"
