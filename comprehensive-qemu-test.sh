#!/bin/bash

# Comprehensive QEMU test for RedoxOS UEFI configurations
set -e

# Configuration
DISK_IMAGE="/tmp/redox-test.img"
OVMF_FD="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF.fd"
OVMF_CODE="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF_CODE.fd"
OVMF_VARS="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF_VARS.fd"
QEMU="/nix/store/1f50kfj62m2vb5gnqn8yvrhd6j5y3nsq-qemu-host-cpu-only-10.1.2/bin/qemu-system-x86_64"
BOOTLOADER="/nix/store/d09w6yb56z8w4hz2mg9dpys93fh1j2p1-redox-disk-image-unstable/boot/EFI/BOOT/BOOTX64.EFI"
TEST_DIR="/tmp/qemu-redox-tests"
TIMEOUT=25

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

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
    ( timeout $TIMEOUT $QEMU \
        -m 2048 \
        -smp 2 \
        -enable-kvm \
        -serial file:"$log_file" \
        -monitor none \
        -display none \
        -device isa-debug-exit \
        $qemu_args \
        2>&1 || true ) | head -10

    # Check log for boot success indicators
    echo "--- Boot log (first 20 lines) ---"
    head -20 "$log_file" 2>/dev/null || echo "No log output"
    echo ""

    if grep -qi "redox.*boot.*complete\|login:" "$log_file" 2>/dev/null; then
        echo "✓ SUCCESS: Boot completed"
    elif grep -qi "redox\|kernel\|bootloader" "$log_file" 2>/dev/null; then
        echo "~ PARTIAL: Some RedoxOS boot progress"
    elif grep -qi "uefi\|bds" "$log_file" 2>/dev/null; then
        echo "- FIRMWARE: UEFI running but no OS boot"
    else
        echo "✗ FAILED: No recognizable boot activity"
    fi
    echo ""
    sleep 2
}

echo "=== COMPREHENSIVE QEMU REDOX BOOT TESTS ==="
echo "Disk image: $DISK_IMAGE"
echo "Bootloader: $BOOTLOADER"
echo "Test directory: $TEST_DIR"
echo ""

# Test 1: Original flake configuration (with direct kernel boot)
run_qemu_test "original-flake-style" \
    -M pc \
    -bios "$OVMF_FD" \
    -kernel "$BOOTLOADER" \
    -drive file="$DISK_IMAGE",format=raw,if=ide

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
run_qemu_test "ovmf-code-vars" \
    -M q35 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file=/tmp/OVMF_VARS_test.fd \
    -drive file="$DISK_IMAGE",format=raw,if=ide

# Test 7: Explicit boot order
run_qemu_test "explicit-boot-order" \
    -M pc \
    -bios "$OVMF_FD" \
    -drive file="$DISK_IMAGE",format=raw,if=ide,bootindex=1 \
    -boot order=c

echo "All tests completed. Logs available in $TEST_DIR"