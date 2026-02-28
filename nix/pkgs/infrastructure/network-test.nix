# Automated network test for RedoxOS
#
# Boots a network-test-enabled Redox disk image with QEMU SLiRP networking,
# watches serial output for NET_TEST results. Validates the full network stack:
#   e1000d driver → smolnetd → DHCP → IP config → DNS → connectivity
#
# Uses QEMU user-mode networking (SLiRP) by default — no root or TAP needed.
# Optionally supports Cloud Hypervisor with TAP for virtio-net testing.
#
# Test protocol:
#   NET_TESTS_START              → test suite beginning
#   NET_TEST:<name>:PASS         → individual test passed
#   NET_TEST:<name>:FAIL:<reason>→ individual test failed
#   NET_TEST:<name>:SKIP         → test skipped
#   NET_TESTS_COMPLETE           → all tests finished
#
# Usage:
#   nix run .#network-test              # QEMU with SLiRP (default)
#   nix run .#network-test -- --verbose # Show serial output
#   nix run .#network-test -- --timeout 120

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
pkgs.writeShellScriptBin "network-test" ''
  set -uo pipefail

  # === Configuration ===
  TIMEOUT="''${NETWORK_TEST_TIMEOUT:-120}"
  MODE="qemu"
  VERBOSE=0

  usage() {
    echo "Usage: network-test [OPTIONS]"
    echo ""
    echo "Automated network test for Redox OS"
    echo "Boots a test image with networking, runs in-guest network tests."
    echo ""
    echo "Options:"
    echo "  --qemu         Use QEMU with SLiRP networking (default, no root needed)"
    echo "  --ch           Use Cloud Hypervisor with TAP (requires TAP setup)"
    echo "  --timeout SEC  Set timeout in seconds (default: 120)"
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
  echo "  ''${BOLD}Redox OS Network Test Suite''${RESET}"
  echo "  ================================="
  echo "  VMM:     $MODE"
  echo "  Timeout: ''${TIMEOUT}s"
  echo "  Image:   $(du -h "$IMAGE" | cut -f1)"
  echo ""

  # === Launch VM with networking ===
  if [ "$MODE" = "ch" ]; then
    # Cloud Hypervisor with TAP networking (requires setup)
    TAP_NAME="''${TAP_NAME:-tap0}"
    if ! ${pkgs.iproute2}/bin/ip link show "$TAP_NAME" &>/dev/null; then
      echo "  ''${RED}ERROR: TAP interface $TAP_NAME not found''${RESET}"
      echo "  Run: sudo nix run .#setup-cloud-hypervisor-network"
      exit 1
    fi
    FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"
    ${cloudHypervisor}/bin/cloud-hypervisor \
      --firmware "$FIRMWARE" \
      --disk path="$IMAGE" \
      --cpus boot=4 \
      --memory size=2048M \
      --net tap="$TAP_NAME",mac=52:54:00:12:34:56,num_queues=2,queue_size=256 \
      --serial file="$SERIAL_LOG" \
      --console off \
      &>"$WORK_DIR/vmm.log" &
    VM_PID=$!
  else
    # QEMU with SLiRP (user-mode) networking — no root/TAP needed
    OVMF="$WORK_DIR/OVMF.fd"
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
    chmod +w "$OVMF"

    # KVM flags (optional, faster but not required)
    KVM_FLAGS=""
    CPU_MODEL="qemu64"
    if [ -w /dev/kvm ] 2>/dev/null; then
      KVM_FLAGS="-enable-kvm"
      CPU_MODEL="host"
    fi

    ${pkgs.qemu}/bin/qemu-system-x86_64 \
      -M pc \
      -cpu $CPU_MODEL \
      -m 2048 \
      -smp 4 \
      $KVM_FLAGS \
      -serial file:"$SERIAL_LOG" \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -bios "$OVMF" \
      -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
      -drive file="$IMAGE",format=raw,if=none,id=disk0 \
      -device virtio-blk-pci,drive=disk0 \
      -netdev user,id=net0 \
      -device e1000,netdev=net0 \
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

  # Phase 1: Wait for boot
  M_BOOT=0

  while true; do
    NOW_MS=$(ms_now)
    ELAPSED_MS=$(( NOW_MS - START_MS ))
    ELAPSED_S=$(( ELAPSED_MS / 1000 ))

    if [ "$ELAPSED_S" -ge "$TIMEOUT" ]; then
      break
    fi

    if ! kill -0 "$VM_PID" 2>/dev/null; then
      sleep 0.3
      break
    fi

    LOG_CONTENT=$(cat "$SERIAL_LOG" 2>/dev/null || true)

    if [ -z "$LOG_CONTENT" ]; then
      sleep 0.1
      continue
    fi

    if [ "$M_BOOT" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "Boot Complete"; then
      M_BOOT=1
      echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Boot complete"
    fi

    # Check for test completion
    if echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "NET_TESTS_COMPLETE"; then
      sleep 0.5  # Let final output flush
      break
    fi

    sleep 0.2
  done

  # Stop verbose tail
  if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
    kill "$TAIL_PID" 2>/dev/null || true
  fi

  FINAL_MS=$(( $(ms_now) - START_MS ))

  # === Parse results ===
  PASS=0
  FAIL=0
  SKIP=0
  RESULTS=""

  while IFS= read -r line; do
    # Strip ANSI escape codes
    clean=$(echo "$line" | ${pkgs.gnused}/bin/sed 's/\x1b\[[0-9;]*m//g')

    if echo "$clean" | ${pkgs.gnugrep}/bin/grep -qE '^NET_TEST:.*:PASS'; then
      name=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/NET_TEST:\(.*\):PASS.*/\1/')
      RESULTS="$RESULTS  ''${GREEN}✓ $name''${RESET}\n"
      PASS=$((PASS + 1))
    elif echo "$clean" | ${pkgs.gnugrep}/bin/grep -qE '^NET_TEST:.*:FAIL'; then
      name=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/NET_TEST:\(.*\):FAIL.*/\1/')
      reason=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/NET_TEST:[^:]*:FAIL:\?\(.*\)/\1/')
      RESULTS="$RESULTS  ''${RED}✗ $name''${RESET}''${reason:+ ($reason)}\n"
      FAIL=$((FAIL + 1))
    elif echo "$clean" | ${pkgs.gnugrep}/bin/grep -qE '^NET_TEST:.*:SKIP'; then
      name=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/NET_TEST:\(.*\):SKIP.*/\1/')
      RESULTS="$RESULTS  ''${YELLOW}○ $name (skipped)''${RESET}\n"
      SKIP=$((SKIP + 1))
    fi
  done < "$SERIAL_LOG"

  TOTAL=$((PASS + FAIL + SKIP))

  echo ""
  echo "  Results:"
  echo -e "$RESULTS"
  echo ""
  echo "  Total: $TOTAL  |  ''${GREEN}Pass: $PASS''${RESET}  |  ''${RED}Fail: $FAIL''${RESET}  |  ''${YELLOW}Skip: $SKIP''${RESET}"
  echo "  Time:  $(fmt_ms $FINAL_MS)"
  echo ""

  if [ "$FAIL" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║         NETWORK TEST PASSED              ║"
    echo "  ╚══════════════════════════════════════════╝"
    exit 0
  elif [ "$TOTAL" -eq 0 ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║   NETWORK TEST FAILED (no results)       ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Last 30 lines of serial output:"
    echo "  ────────────────────────────────────────"
    tail -30 "$SERIAL_LOG" 2>/dev/null | ${pkgs.gnused}/bin/sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    exit 1
  else
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║   NETWORK TEST FAILED ($FAIL failures)      ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Network-related serial output:"
    echo "  ────────────────────────────────────────"
    ${pkgs.gnugrep}/bin/grep -i 'net\|dhcp\|e1000\|eth0\|addr\|dns\|ping\|tcp\|error\|panic' "$SERIAL_LOG" 2>/dev/null | ${pkgs.gnused}/bin/sed 's/^/  /' | head -40
    echo "  ────────────────────────────────────────"
    exit 1
  fi
''
