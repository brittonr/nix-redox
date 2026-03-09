# Automated network install test for RedoxOS
#
# End-to-end test proving snix can install packages from a remote HTTP binary cache.
#
# Architecture:
#   1. Build a test binary cache (packages.json + narinfo + NARs) at Nix build time
#   2. Start a Python HTTP server on the host serving the cache on port 8080
#   3. Boot QEMU with SLiRP networking (guest at 10.0.2.15, host at 10.0.2.2)
#   4. Guest runs snix search/install/show against http://10.0.2.2:8080
#   5. Parse FUNC_TEST results from serial console
#
# Usage:
#   nix run .#network-install-test              # Run test
#   nix run .#network-install-test -- --verbose # Show serial output
#   nix run .#network-install-test -- --timeout 180

{
  pkgs,
  lib,
  diskImage,
  bootloader,
  testCache, # Pre-built binary cache directory with packages.json + NARs
}:

let
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;
in
pkgs.writeShellScriptBin "network-install-test" ''
  set -uo pipefail

  # === Configuration ===
  TIMEOUT="''${NETWORK_INSTALL_TEST_TIMEOUT:-180}"
  VERBOSE=0
  # Use a port less likely to conflict. QEMU SLiRP makes the host reachable
  # at 10.0.2.2 from the guest. The guest connects to 10.0.2.2:$HTTP_PORT.
  HTTP_PORT=''${NETWORK_INSTALL_TEST_PORT:-18080}

  usage() {
    echo "Usage: network-install-test [OPTIONS]"
    echo ""
    echo "Network install test for Redox OS"
    echo "Boots a test image with networking, serves a binary cache via HTTP,"
    echo "and verifies snix can install packages from the remote cache."
    echo ""
    echo "Options:"
    echo "  --timeout SEC  Set timeout in seconds (default: 180)"
    echo "  --verbose      Show serial output in real time"
    echo "  --help         Show this help"
    exit 0
  }

  while [ $# -gt 0 ]; do
    case "$1" in
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
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
  else
    GREEN="" RED="" YELLOW="" BOLD="" RESET=""
  fi

  # === Setup ===
  WORK_DIR=$(mktemp -d)
  cleanup() {
    if [ -n "''${HTTP_PID:-}" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
      kill "$HTTP_PID" 2>/dev/null || true
      wait "$HTTP_PID" 2>/dev/null || true
    fi
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
  HTTP_PID=""

  cp ${diskImage}/redox.img "$IMAGE"
  chmod +w "$IMAGE"
  touch "$SERIAL_LOG"

  echo ""
  echo "  ''${BOLD}Redox OS Network Install Test''${RESET}"
  echo "  ===================================="
  echo "  Timeout: ''${TIMEOUT}s"
  echo "  Image:   $(du -h "$IMAGE" | cut -f1)"
  echo "  Cache:   ${testCache}"
  echo ""

  # === Start HTTP server serving the test binary cache ===
  echo "  Starting HTTP server on port $HTTP_PORT..."
  ${pkgs.python3}/bin/python3 -m http.server "$HTTP_PORT" \
    --directory "${testCache}" \
    --bind 0.0.0.0 \
    &>"$WORK_DIR/http.log" &
  HTTP_PID=$!

  # Wait a moment for the server to start
  sleep 0.5
  if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "  ''${RED}ERROR: HTTP server failed to start''${RESET}"
    cat "$WORK_DIR/http.log"
    exit 1
  fi
  echo "  HTTP server started (PID: $HTTP_PID)"

  # Verify the server is serving packages.json
  if ${pkgs.curl}/bin/curl -s -f "http://127.0.0.1:$HTTP_PORT/packages.json" > /dev/null 2>&1; then
    echo "  Cache verified: packages.json accessible"
  else
    echo "  ''${RED}ERROR: packages.json not accessible at http://127.0.0.1:$HTTP_PORT''${RESET}"
    cat "$WORK_DIR/http.log"
    exit 1
  fi

  # === Launch VM with SLiRP networking ===
  OVMF="$WORK_DIR/OVMF.fd"
  cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
  chmod +w "$OVMF"

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

  echo "  VM started (PID: $VM_PID)"
  echo ""

  if [ "$VERBOSE" = "1" ]; then
    tail -f "$SERIAL_LOG" 2>/dev/null &
    TAIL_PID=$!
  fi

  # === Poll for results ===
  ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
  fmt_ms() {
    local ms=$1
    echo "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))s"
  }

  START_MS=$(ms_now)
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

    if echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "FUNC_TESTS_COMPLETE"; then
      sleep 0.5
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
    clean=$(echo "$line" | ${pkgs.gnused}/bin/sed 's/\x1b\[[0-9;]*m//g')

    if echo "$clean" | ${pkgs.gnugrep}/bin/grep -qE '^FUNC_TEST:.*:PASS'; then
      name=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/FUNC_TEST:\(.*\):PASS.*/\1/')
      RESULTS="$RESULTS  ''${GREEN}✓ $name''${RESET}\n"
      PASS=$((PASS + 1))
    elif echo "$clean" | ${pkgs.gnugrep}/bin/grep -qE '^FUNC_TEST:.*:FAIL'; then
      name=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/FUNC_TEST:\(.*\):FAIL.*/\1/')
      reason=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/FUNC_TEST:[^:]*:FAIL:\?\(.*\)/\1/')
      RESULTS="$RESULTS  ''${RED}✗ $name''${RESET}''${reason:+ ($reason)}\n"
      FAIL=$((FAIL + 1))
    elif echo "$clean" | ${pkgs.gnugrep}/bin/grep -qE '^FUNC_TEST:.*:SKIP'; then
      name=$(echo "$clean" | ${pkgs.gnused}/bin/sed 's/FUNC_TEST:\(.*\):SKIP.*/\1/')
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

  # Show HTTP server activity
  HTTP_REQUESTS=$(${pkgs.gnugrep}/bin/grep -c '"GET ' "$WORK_DIR/http.log" 2>/dev/null || echo 0)
  echo "  HTTP server: $HTTP_REQUESTS GET requests served"
  if [ "$VERBOSE" = "1" ] && [ -s "$WORK_DIR/http.log" ]; then
    echo ""
    echo "  HTTP log (last 20 lines):"
    echo "  ────────────────────────────────────────"
    tail -20 "$WORK_DIR/http.log" | ${pkgs.gnused}/bin/sed 's/^/  /'
    echo "  ────────────────────────────────────────"
  fi
  echo ""

  if [ "$FAIL" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║     NETWORK INSTALL TEST PASSED          ║"
    echo "  ╚══════════════════════════════════════════╝"
    exit 0
  elif [ "$TOTAL" -eq 0 ]; then
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║  NETWORK INSTALL TEST FAILED (no results)║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Last 30 lines of serial output:"
    echo "  ────────────────────────────────────────"
    tail -30 "$SERIAL_LOG" 2>/dev/null | ${pkgs.gnused}/bin/sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    exit 1
  else
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║  NETWORK INSTALL TEST FAILED             ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    echo "  Last 30 lines of serial output:"
    echo "  ────────────────────────────────────────"
    tail -30 "$SERIAL_LOG" 2>/dev/null | ${pkgs.gnused}/bin/sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    exit 1
  fi
''
