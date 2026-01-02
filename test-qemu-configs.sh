#!/bin/bash

# Test script for different QEMU configurations with RedoxOS UEFI image
set -e

# Configuration
DISK_IMAGE="/tmp/redox-test.img"
OVMF_FD="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF.fd"
OVMF_CODE="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF_CODE.fd"
OVMF_VARS="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF_VARS.fd"
QEMU="/nix/store/1f50kfj62m2vb5gnqn8yvrhd6j5y3nsq-qemu-host-cpu-only-10.1.2/bin/qemu-system-x86_64"
TEST_DIR="/tmp/qemu-redox-tests"
TIMEOUT=30

# Check if disk image exists
if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "Error: Disk image not found at $DISK_IMAGE"
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
    timeout $TIMEOUT $QEMU \
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
        echo "✓ SUCCESS: Boot appears successful"
    elif grep -q "UEFI\|RedoxFS\|kernel" "$log_file" 2>/dev/null; then
        echo "~ PARTIAL: Some boot progress detected"
    else
        echo "✗ FAILED: No boot progress detected"
    fi
    echo ""
    sleep 2
}

echo "Starting QEMU configuration tests for RedoxOS UEFI boot"
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