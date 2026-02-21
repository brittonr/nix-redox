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
#   - Cloud Hypervisor (default): Requires KVM, fast boot (~1-2s)
#   - QEMU TCG (fallback): No KVM needed, slower (~60-120s)
#
# Milestones tracked on serial console (in boot order):
#   1. "Redox OS Bootloader"   → UEFI loaded our bootloader
#   2. "Redox OS starting"     → kernel is executing
#   3. "Boot Complete"         → rootfs mounted, init.d scripts ran
#   4. "ion>" or "Welcome"     → shell/login prompt ready
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
    if [ -n "''${VM_PID:-}" ] && kill -0 "$VM_PID" 2>/dev/null; then
      kill "$VM_PID" 2>/dev/null || true
      wait "$VM_PID" 2>/dev/null || true
    fi
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
      -vga none \
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
  # Each milestone has a specific pattern that matches exactly one boot phase.
  # We scan the full log each poll — on CH+KVM the entire boot completes in <1s
  # so incremental reads add complexity without value. On QEMU TCG, the full
  # scan is still fast (serial log is small).
  M_BOOTLOADER=0
  M_KERNEL=0
  M_BOOT=0
  M_SHELL=0

  # Use millisecond timestamps for accurate boot timing.
  # date +%s%N gives nanoseconds; we divide to get milliseconds.
  ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
  fmt_ms() {
    local ms=$1
    echo "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))s"
  }

  START_MS=$(ms_now)

  while true; do
    NOW_MS=$(ms_now)
    ELAPSED_MS=$(( NOW_MS - START_MS ))
    ELAPSED_S=$(( ELAPSED_MS / 1000 ))

    if [ "$ELAPSED_S" -ge "$TIMEOUT" ]; then
      break
    fi

    if ! kill -0 "$VM_PID" 2>/dev/null; then
      sleep 0.2  # let final output flush
      break
    fi

    LOG_CONTENT=$(cat "$SERIAL_LOG" 2>/dev/null || true)

    if [ -z "$LOG_CONTENT" ]; then
      sleep 0.1
      continue
    fi

    # Milestone 1: Bootloader — our bootloader binary is running
    # Pattern: "Redox OS Bootloader" (printed by bootloader on startup)
    if [ "$M_BOOTLOADER" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Redox OS Bootloader"; then
      M_BOOTLOADER=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Bootloader started"
    fi

    # Milestone 2: Kernel — the Redox kernel is executing
    # Pattern: "Redox OS starting" (first kernel log line after handoff from bootloader)
    if [ "$M_KERNEL" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Redox OS starting"; then
      M_KERNEL=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Kernel running"
    fi

    # Milestone 3: Boot complete — rootfs mounted, init.d scripts ran, userspace ready
    # Pattern: "Boot Complete" (echo'd by 90_exit_initfs init script)
    if [ "$M_BOOT" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Boot Complete"; then
      M_BOOT=1
      BOOT_MS=$ELAPSED_MS
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Boot complete"
    fi

    # Milestone 4: Shell — interactive prompt is ready
    # Pattern: "ion>" (ion shell prompt) or "Welcome to Redox" (login banner)
    if [ "$M_SHELL" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -qE "(ion>|Welcome to Redox)"; then
      M_SHELL=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Shell ready"
    fi

    # All milestones reached
    if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "1" ]; then
      break
    fi

    # After boot complete, give shell up to 10s to appear
    if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "0" ]; then
      if [ "$(( (ELAPSED_MS - BOOT_MS) / 1000 ))" -ge 10 ]; then
        break
      fi
    fi

    sleep 0.1
  done

  # Stop verbose tail
  if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
    kill "$TAIL_PID" 2>/dev/null || true
  fi

  FINAL_MS=$(( $(ms_now) - START_MS ))

  # === Report results ===
  echo ""
  echo "  Milestones:"
  [ "$M_BOOTLOADER" = "1" ] && echo "    ✓ bootloader"  || echo "    ✗ bootloader"
  [ "$M_KERNEL" = "1" ]     && echo "    ✓ kernel"      || echo "    ✗ kernel"
  [ "$M_BOOT" = "1" ]       && echo "    ✓ boot"        || echo "    ✗ boot"
  [ "$M_SHELL" = "1" ]      && echo "    ✓ shell"       || echo "    ✗ shell"
  echo ""
  echo "  Total time: $(fmt_ms $FINAL_MS)"
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
