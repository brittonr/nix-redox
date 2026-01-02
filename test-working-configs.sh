#!/bin/bash

# Test script for working QEMU configurations with RedoxOS using direct kernel boot
set -e

# Configuration
DISK_IMAGE="/tmp/redox-test.img"
OVMF_FD="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF.fd"
OVMF_CODE="/nix/store/247gazc666hygyws1vi5wln3qyxg94ny-OVMF-202511-fd/FV/OVMF_CODE.fd"
OVMF_VARS="/tmp/OVMF_VARS_test.fd"
QEMU="/nix/store/1f50kfj62m2vb5gnqn8yvrhd6j5y3nsq-qemu-host-cpu-only-10.1.2/bin/qemu-system-x86_64"
BOOTLOADER="/tmp/bootx64-redox.efi"
TEST_DIR="/tmp/qemu-redox-working-tests"
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

    local log_file="$TEST_DIR/${test_name}.log"

    # Run QEMU with timeout and expect resolution selection
    ( timeout $TIMEOUT $QEMU \
        -m 2048 \
        -smp 2 \
        -enable-kvm \
        -kernel "$BOOTLOADER" \
        -serial file:"$log_file" \
        -monitor none \
        -display none \
        -device isa-debug-exit \
        $qemu_args \
        2>&1 || true ) | head -15

    # Check log for boot success indicators
    echo ""
    echo "--- Boot results ---"
    if grep -q "RedoxFS.*MiB" "$log_file" 2>/dev/null; then
        echo "✓ SUCCESS: RedoxFS filesystem detected"
        if grep -q "Output.*resolution" "$log_file" 2>/dev/null; then
            echo "✓ SUCCESS: Display resolution menu shown"
        fi
    elif grep -q "Redox OS Bootloader" "$log_file" 2>/dev/null; then
        echo "~ PARTIAL: Bootloader started but filesystem issues"
    else
        echo "✗ FAILED: Bootloader did not start"
    fi

    echo ""
    sleep 2
}

echo "=== TESTING WORKING QEMU CONFIGS FOR REDOX ==="
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
chmod 644 /tmp/OVMF_VARS_test.fd
run_qemu_test "ovmf-code-vars-setup" \
    -M q35 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$DISK_IMAGE",format=raw,if=ide

echo "=== SUMMARY ==="
echo "All tests completed. Successful configurations will show 'RedoxFS' detection."
echo "Logs available in: $TEST_DIR"