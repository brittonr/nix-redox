# Automated boot test for RedoxOS
#
# Boots a Redox disk image in a VM, watches serial output for boot milestones,
# and exits with 0 (pass) or 1 (fail). Designed for CI and local validation.
#
# Architecture: VM runs in background with serial output written to a file.
# The test script polls the file for milestone strings. This avoids all
# pty/expect buffering complexity.
#
# Supports two VMM backends:
#   - Cloud Hypervisor (default): Requires KVM, fast boot (~5-10s)
#   - QEMU TCG (fallback): No KVM needed, slower (~60-120s)
#
# Milestones tracked on serial console:
#   1. Any output         → firmware/bootloader started
#   2. "initfs"           → kernel booted, initfs executing
#   3. "Boot Complete"    → full system boot (SUCCESS)
#   4. "ion>"             → shell prompt ready (bonus)
#
# Usage:
#   nix run .#boot-test              # Auto-detect (CH if KVM, else QEMU)
#   nix run .#boot-test -- --qemu    # Force QEMU TCG mode
#   nix run .#boot-test -- --timeout 120
#   BOOT_TEST_TIMEOUT=60 nix run .#boot-test

{
  pkgs,
  lib,
  diskImage,
  bootloader,
}:

let
  cloudHypervisor = pkgs.cloud-hypervisor;
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;
in
pkgs.writeShellScriptBin "boot-test" ''
  set -uo pipefail

  # === Configuration ===
  TIMEOUT="''${BOOT_TEST_TIMEOUT:-90}"
  MODE="auto"
  VERBOSE=0

  usage() {
    echo "Usage: boot-test [OPTIONS]"
    echo ""
    echo "Automated boot test for Redox OS"
    echo ""
    echo "Options:"
    echo "  --qemu         Force QEMU TCG mode (no KVM required)"
    echo "  --ch           Force Cloud Hypervisor mode (KVM required)"
    echo "  --timeout SEC  Set timeout in seconds (default: 90, env: BOOT_TEST_TIMEOUT)"
    echo "  --verbose      Show serial output in real time"
    echo "  --help         Show this help"
    exit 0
  }

  while [ $# -gt 0 ]; do
    case "$1" in
      --qemu)    MODE="qemu"; shift ;;
      --ch)      MODE="ch"; shift ;;
      --timeout) TIMEOUT="$2"; shift 2 ;;
      --verbose) VERBOSE=1; shift ;;
      --help)    usage ;;
      *)         echo "Unknown option: $1"; usage ;;
    esac
  done

  # Auto-detect VMM
  if [ "$MODE" = "auto" ]; then
    if [ -w /dev/kvm ] 2>/dev/null; then
      MODE="ch"
    else
      echo "  Warning: /dev/kvm not available — falling back to QEMU TCG (slower)"
      MODE="qemu"
      if [ "$TIMEOUT" -lt 180 ]; then
        TIMEOUT=180
      fi
    fi
  fi

  # === Setup ===
  WORK_DIR=$(mktemp -d)
  cleanup() {
    # Kill VM if still running
    if [ -n "''${VM_PID:-}" ] && kill -0 "$VM_PID" 2>/dev/null; then
      kill "$VM_PID" 2>/dev/null || true
      wait "$VM_PID" 2>/dev/null || true
    fi
    # Kill tail if running
    if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
      kill "$TAIL_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
  }
  trap cleanup EXIT

  IMAGE="$WORK_DIR/redox.img"
  SERIAL_LOG="$WORK_DIR/serial.log"
  VM_PID=""
  TAIL_PID=""

  cp ${diskImage}/redox.img "$IMAGE"
  chmod +w "$IMAGE"
  touch "$SERIAL_LOG"

  echo ""
  echo "  Redox OS Automated Boot Test"
  echo "  ============================="
  echo "  VMM:     $MODE"
  echo "  Timeout: ''${TIMEOUT}s"
  echo "  Image:   $(du -h "$IMAGE" | cut -f1)"
  echo ""

  # === Launch VM in background with serial to file ===
  if [ "$MODE" = "ch" ]; then
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk path="$IMAGE" \
      --cpus boot=2 \
      --memory size=1024M \
      --serial file="$SERIAL_LOG" \
      --console off \
      &>"$WORK_DIR/vmm.log" &
    VM_PID=$!
  else
    OVMF="$WORK_DIR/OVMF.fd"
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
    chmod +w "$OVMF"
    ${pkgs.qemu}/bin/qemu-system-x86_64 \
      -M pc \
      -cpu qemu64 \
      -m 1024 \
      -smp 2 \
      -serial file:"$SERIAL_LOG" \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -bios "$OVMF" \
      -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
      -drive file="$IMAGE",format=raw,if=none,id=disk0 \
      -device virtio-blk-pci,drive=disk0 \
      -display none \
      -no-reboot \
      &>"$WORK_DIR/vmm.log" &
    VM_PID=$!
  fi

  echo "  VM started (PID: $VM_PID)"
  echo ""

  # Show serial output in real time if verbose
  if [ "$VERBOSE" = "1" ]; then
    tail -f "$SERIAL_LOG" 2>/dev/null &
    TAIL_PID=$!
  fi

  # === Poll serial log for milestones ===
  M_FIRMWARE=0
  M_INITFS=0
  M_BOOT=0
  M_SHELL=0
  START_TIME=$(date +%s)
  LAST_SIZE=0

  while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))

    # Check timeout
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
      break
    fi

    # Check if VM died
    if ! kill -0 "$VM_PID" 2>/dev/null; then
      # Give a moment for final log output to flush
      sleep 1
      break
    fi

    # Read the serial log
    CURRENT_SIZE=$(${pkgs.coreutils}/bin/stat -c%s "$SERIAL_LOG" 2>/dev/null || echo 0)

    if [ "$CURRENT_SIZE" -gt "$LAST_SIZE" ]; then
      # New output available — read the new portion
      NEW_OUTPUT=$(${pkgs.coreutils}/bin/tail -c +"$((LAST_SIZE + 1))" "$SERIAL_LOG" 2>/dev/null || true)
      LAST_SIZE="$CURRENT_SIZE"

      # Check firmware (any output at all)
      if [ "$M_FIRMWARE" = "0" ] && [ "$CURRENT_SIZE" -gt 0 ]; then
        M_FIRMWARE=1
        echo "  ✓ [''${ELAPSED}s] Firmware/bootloader started"
      fi

      # Check initfs
      if [ "$M_INITFS" = "0" ] && echo "$NEW_OUTPUT" | ${pkgs.gnugrep}/bin/grep -q "initfs"; then
        M_INITFS=1
        echo "  ✓ [''${ELAPSED}s] InitFS reached"
      fi

      # Check boot complete
      if [ "$M_BOOT" = "0" ] && echo "$NEW_OUTPUT" | ${pkgs.gnugrep}/bin/grep -q "Boot Complete"; then
        M_BOOT=1
        echo "  ✓ [''${ELAPSED}s] Boot complete"
      fi

      # Check shell
      if [ "$M_SHELL" = "0" ] && echo "$NEW_OUTPUT" | ${pkgs.gnugrep}/bin/grep -qE "(ion>|Welcome to Redox)"; then
        M_SHELL=1
        echo "  ✓ [''${ELAPSED}s] Shell ready"
      fi

      # After boot complete, wait for shell to appear
      if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "1" ]; then
        break
      fi

      # If boot is complete, keep polling for shell (up to 10s extra)
      if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "0" ]; then
        BOOT_ELAPSED=$(( $(date +%s) - START_TIME ))
        if [ -z "''${BOOT_TIME:-}" ]; then
          BOOT_TIME=$BOOT_ELAPSED
        fi
        # Give shell up to 10s after boot complete
        if [ "$((BOOT_ELAPSED - BOOT_TIME))" -ge 10 ]; then
          break
        fi
      fi
    fi

    sleep 1
  done

  # Stop verbose tail
  if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
    kill "$TAIL_PID" 2>/dev/null || true
  fi

  ELAPSED=$(( $(date +%s) - START_TIME ))

  # === Report results ===
  echo ""
  echo "  Milestones:"
  [ "$M_FIRMWARE" = "1" ] && echo "    ✓ firmware"  || echo "    ✗ firmware"
  [ "$M_INITFS" = "1" ]   && echo "    ✓ initfs"    || echo "    ✗ initfs"
  [ "$M_BOOT" = "1" ]     && echo "    ✓ boot"      || echo "    ✗ boot"
  [ "$M_SHELL" = "1" ]    && echo "    ✓ shell"     || echo "    ✗ shell"
  echo ""
  echo "  Total time: ''${ELAPSED}s"
  echo ""

  if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "1" ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║            BOOT TEST PASSED              ║"
    echo "  ╚══════════════════════════════════════════╝"
    exit 0
  elif [ "$M_BOOT" = "1" ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║     BOOT TEST PARTIAL (no shell)         ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Last 15 lines of serial output:"
    echo "  ────────────────────────────────────────"
    tail -15 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    exit 1
  else
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║            BOOT TEST FAILED              ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Last 30 lines of serial output:"
    echo "  ────────────────────────────────────────"
    tail -30 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    if [ -s "$WORK_DIR/vmm.log" ]; then
      echo ""
      echo "  VMM output:"
      echo "  ────────────────────────────────────────"
      cat "$WORK_DIR/vmm.log" | sed 's/^/  /'
      echo "  ────────────────────────────────────────"
    fi
    exit 1
  fi
''
