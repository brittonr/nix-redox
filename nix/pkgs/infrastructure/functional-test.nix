# Automated functional test for RedoxOS
#
# Boots a test-enabled Redox disk image, watches serial output for:
# 1. Boot milestones (same as boot-test)
# 2. Functional test results (FUNC_TEST:name:PASS/FAIL)
# Includes ~50 in-guest tests: shell, filesystem, CLI tools, Nix evaluator,
# system manifest introspection, and generation management.
#
# The test image includes a modified startup script that runs an Ion shell
# test suite instead of launching an interactive shell. This avoids all
# pty/expect complexity — tests run natively inside the guest and write
# structured results to serial output.
#
# Test protocol:
#   FUNC_TESTS_START              → test suite beginning
#   FUNC_TEST:<name>:PASS         → individual test passed
#   FUNC_TEST:<name>:FAIL:<reason>→ individual test failed
#   FUNC_TEST:<name>:SKIP         → test skipped (tool not available)
#   FUNC_TESTS_COMPLETE           → all tests finished
#
# Usage:
#   nix run .#functional-test              # Auto-detect VMM
#   nix run .#functional-test -- --qemu    # Force QEMU TCG
#   nix run .#functional-test -- --verbose # Show serial output
#   nix run .#functional-test -- --timeout 120

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
pkgs.writeShellScriptBin "functional-test" ''
  set -uo pipefail

  # === Configuration ===
  TIMEOUT="''${FUNCTIONAL_TEST_TIMEOUT:-120}"
  MODE="auto"
  VERBOSE=0

  usage() {
    echo "Usage: functional-test [OPTIONS]"
    echo ""
    echo "Automated functional test for Redox OS"
    echo "Boots a test image, runs ~50 in-guest tests, reports results."
    echo ""
    echo "Options:"
    echo "  --qemu         Force QEMU TCG mode (no KVM required)"
    echo "  --ch           Force Cloud Hypervisor mode (KVM required)"
    echo "  --timeout SEC  Set timeout in seconds (default: 120, env: FUNCTIONAL_TEST_TIMEOUT)"
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
      if [ "$TIMEOUT" -lt 300 ]; then
        TIMEOUT=300
      fi
    fi
  fi

  # === Color support ===
  if [ -t 1 ]; then
    GREEN=$'\033[32m'
    RED=$'\033[31m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
  else
    GREEN="" RED="" YELLOW="" CYAN="" BOLD="" RESET=""
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
  echo "  ''${BOLD}Redox OS Functional Test Suite''${RESET}"
  echo "  ====================================="
  echo "  VMM:     $MODE"
  echo "  Timeout: ''${TIMEOUT}s"
  echo "  Image:   $(du -h "$IMAGE" | cut -f1)"
  echo ""

  # === Launch VM ===
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

  if [ "$VERBOSE" = "1" ]; then
    tail -f "$SERIAL_LOG" 2>/dev/null &
    TAIL_PID=$!
  fi

  # === Milestone tracking ===
  ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
  fmt_ms() {
    local ms=$1
    echo "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))s"
  }

  START_MS=$(ms_now)

  # Phase 1: Wait for boot milestones
  M_BOOTLOADER=0
  M_KERNEL=0
  M_BOOT=0
  M_SHELL=0

  # Phase 2: Track functional tests
  TESTS_STARTED=0
  TESTS_COMPLETE=0
  PASS_COUNT=0
  FAIL_COUNT=0
  SKIP_COUNT=0
  LAST_PARSED_LINE=0

  echo "  ''${CYAN}Phase 1: Boot''${RESET}"

  while true; do
    NOW_MS=$(ms_now)
    ELAPSED_MS=$(( NOW_MS - START_MS ))
    ELAPSED_S=$(( ELAPSED_MS / 1000 ))

    if [ "$ELAPSED_S" -ge "$TIMEOUT" ]; then
      break
    fi

    if ! kill -0 "$VM_PID" 2>/dev/null; then
      sleep 0.2
      break
    fi

    LOG_CONTENT=$(cat "$SERIAL_LOG" 2>/dev/null || true)

    if [ -z "$LOG_CONTENT" ]; then
      sleep 0.1
      continue
    fi

    # Boot milestones (same as boot-test)
    if [ "$M_BOOTLOADER" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Redox OS Bootloader"; then
      M_BOOTLOADER=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Bootloader started"
    fi

    if [ "$M_KERNEL" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Redox OS starting"; then
      M_KERNEL=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Kernel running"
    fi

    if [ "$M_BOOT" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Boot Complete"; then
      M_BOOT=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Boot complete"
      echo ""
      echo "  ''${CYAN}Phase 2: Functional Tests''${RESET}"
    fi

    # Functional test tracking
    if [ "$TESTS_STARTED" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "FUNC_TESTS_START"; then
      TESTS_STARTED=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Test suite started"
      echo ""
    fi

    # Parse new FUNC_TEST lines incrementally
    if [ "$TESTS_STARTED" = "1" ]; then
      CURRENT_LINES=$(echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:" 2>/dev/null | wc -l)
      if [ "$CURRENT_LINES" -gt "$LAST_PARSED_LINE" ]; then
        echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:" 2>/dev/null | tail -n +"$((LAST_PARSED_LINE + 1))" | while IFS=: read -r _marker name result reason; do
          case "$result" in
            PASS)
              echo "    ''${GREEN}✓''${RESET} $name"
              ;;
            FAIL)
              echo "    ''${RED}✗''${RESET} $name: $reason"
              ;;
            SKIP)
              echo "    ''${YELLOW}⊘''${RESET} $name (skipped)"
              ;;
          esac
        done
        LAST_PARSED_LINE=$CURRENT_LINES
      fi
    fi

    # Check for test completion
    if [ "$TESTS_COMPLETE" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "FUNC_TESTS_COMPLETE"; then
      TESTS_COMPLETE=1
      echo ""
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Test suite complete"
      break
    fi

    sleep 0.1
  done

  # Stop verbose tail
  if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
    kill "$TAIL_PID" 2>/dev/null || true
  fi

  FINAL_MS=$(( $(ms_now) - START_MS ))

  # === Parse final results ===
  PASS_COUNT=0
  FAIL_COUNT=0
  SKIP_COUNT=0
  if [ -f "$SERIAL_LOG" ]; then
    PASS_COUNT=$(${pkgs.gnugrep}/bin/grep -c "^FUNC_TEST:.*:PASS" "$SERIAL_LOG" 2>/dev/null) || PASS_COUNT=0
    FAIL_COUNT=$(${pkgs.gnugrep}/bin/grep -c "^FUNC_TEST:.*:FAIL" "$SERIAL_LOG" 2>/dev/null) || FAIL_COUNT=0
    SKIP_COUNT=$(${pkgs.gnugrep}/bin/grep -c "^FUNC_TEST:.*:SKIP" "$SERIAL_LOG" 2>/dev/null) || SKIP_COUNT=0
  fi

  TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

  # === Report ===
  echo ""
  echo "  ''${BOLD}Results''${RESET}"
  echo "  ─────────────────────────────────"
  echo "    ''${GREEN}Passed:''${RESET}  $PASS_COUNT"
  echo "    ''${RED}Failed:''${RESET}  $FAIL_COUNT"
  echo "    ''${YELLOW}Skipped:''${RESET} $SKIP_COUNT"
  echo "    Total:   $TOTAL_COUNT"
  echo ""
  echo "  Total time: $(fmt_ms $FINAL_MS)"
  echo ""

  # Show failures in detail
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  ''${RED}Failed tests:''${RESET}"
    ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:.*:FAIL" "$SERIAL_LOG" 2>/dev/null | while IFS=: read -r _marker name _fail reason; do
      echo "    ✗ $name: $reason"
    done
    echo ""
  fi

  # Final verdict
  if [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" = "0" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       ''${GREEN}FUNCTIONAL TESTS PASSED''${RESET}            ║"
    echo "  ╚══════════════════════════════════════════╝"
    exit 0
  elif [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       ''${RED}FUNCTIONAL TESTS FAILED''${RESET}            ║"
    echo "  ║       $FAIL_COUNT of $TOTAL_COUNT tests failed            ║"
    echo "  ╚══════════════════════════════════════════╝"
    exit 1
  elif [ "$M_BOOT" = "0" ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       ''${RED}BOOT FAILED''${RESET}                        ║"
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
  else
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       ''${RED}TESTS DID NOT COMPLETE''${RESET}             ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Last 30 lines of serial output:"
    echo "  ────────────────────────────────────────"
    tail -30 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    exit 1
  fi
''
