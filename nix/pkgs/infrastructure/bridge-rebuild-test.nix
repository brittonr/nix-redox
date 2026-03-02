# bridge-rebuild-test — End-to-end integration test for the build bridge
#
# Unlike bridge-test.nix (which uses a mock daemon), this test runs the REAL
# build-bridge daemon: guest edits config → host builds via `nix build` →
# exports to shared cache → guest installs + activates.
#
# Requires KVM + access to the flake directory (for `nix build`).
# NOT hermetic — depends on Nix store and network for first build.

{
  pkgs,
  lib,
  diskImage,
  buildBridge,
}:

let
  cloudHypervisor = pkgs.cloud-hypervisor;
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;
in
pkgs.writeShellScriptBin "bridge-rebuild-test" ''
  set -uo pipefail

  TIMEOUT="''${BRIDGE_REBUILD_TIMEOUT:-300}"
  VERBOSE=0
  FLAKE_DIR="''${REDOX_FLAKE_DIR:-$(pwd)}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) TIMEOUT="$2"; shift 2 ;;
      --verbose) VERBOSE=1; shift ;;
      --flake-dir) FLAKE_DIR="$2"; shift 2 ;;
      --help)
        echo "Usage: bridge-rebuild-test [OPTIONS]"
        echo ""
        echo "End-to-end test: guest sends rebuild config, host builds via nix,"
        echo "exports to shared cache, guest installs and activates."
        echo ""
        echo "Options:"
        echo "  --timeout SEC     Max wait time (default: 300)"
        echo "  --verbose         Show full serial output"
        echo "  --flake-dir DIR   Path to Redox flake (default: cwd)"
        exit 0
        ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Require KVM
  if [ ! -w /dev/kvm ]; then
    echo "ERROR: /dev/kvm not available. This test requires KVM."
    exit 1
  fi

  # Verify flake dir
  if [ ! -f "$FLAKE_DIR/flake.nix" ]; then
    echo "ERROR: No flake.nix in $FLAKE_DIR"
    echo "Use --flake-dir or run from the redox repo root."
    exit 1
  fi

  # Colors
  if [ -t 1 ]; then
    GREEN=$'\033[32m' RED=$'\033[31m' YELLOW=$'\033[33m'
    CYAN=$'\033[36m' BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
  else
    GREEN="" RED="" YELLOW="" CYAN="" BLUE="" BOLD="" RESET=""
  fi

  # Setup
  WORK_DIR=$(mktemp -d)
  SHARED_DIR="$WORK_DIR/shared"
  SERIAL_LOG="$WORK_DIR/serial.log"
  VMM_LOG="$WORK_DIR/vmm.log"
  VIRTIOFSD_LOG="$WORK_DIR/virtiofsd.log"
  BRIDGE_LOG="$WORK_DIR/bridge.log"
  VIRTIOFSD_SOCKET="$WORK_DIR/virtiofsd.sock"
  IMAGE="$WORK_DIR/redox.img"
  VM_PID=""
  VIRTIOFSD_PID=""
  BRIDGE_PID=""
  TAIL_PID=""

  cleanup() {
    if [ -n "''${BRIDGE_PID:-}" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
      kill "$BRIDGE_PID" 2>/dev/null || true
      wait "$BRIDGE_PID" 2>/dev/null || true
    fi
    if [ -n "''${VM_PID:-}" ] && kill -0 "$VM_PID" 2>/dev/null; then
      kill "$VM_PID" 2>/dev/null || true
      wait "$VM_PID" 2>/dev/null || true
    fi
    if [ -n "''${VIRTIOFSD_PID:-}" ] && kill -0 "$VIRTIOFSD_PID" 2>/dev/null; then
      kill "$VIRTIOFSD_PID" 2>/dev/null || true
      wait "$VIRTIOFSD_PID" 2>/dev/null || true
    fi
    if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
      kill "$TAIL_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
  }
  trap cleanup EXIT

  mkdir -p "$SHARED_DIR"/{cache,requests,responses}
  touch "$SERIAL_LOG"

  # Pre-populate a marker file for the guest's poll delay mechanism.
  # The guest reads this file repeatedly through FUSE to burn wall-clock time.
  echo "StoreDir: /nix/store" > "$SHARED_DIR/cache/nix-cache-info"

  echo ""
  echo "  ''${BOLD}Bridge Rebuild Integration Test''${RESET}"
  echo "  ════════════════════════════════"
  echo "  Timeout:   ''${TIMEOUT}s"
  echo "  Flake dir: $FLAKE_DIR"
  echo ""

  # Timing
  ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
  fmt_ms() { local ms=$1; echo "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))s"; }
  START_MS=$(ms_now)

  # ================================================================
  # Phase 1: Start virtiofsd + Cloud Hypervisor
  # ================================================================
  echo "  ''${CYAN}Phase 1: Boot VM with virtio-fs''${RESET}"

  cp ${diskImage}/redox.img "$IMAGE"
  chmod +w "$IMAGE"

  # Start virtiofsd
  rm -f "$VIRTIOFSD_SOCKET"
  ${pkgs.virtiofsd}/bin/virtiofsd \
    --socket-path="$VIRTIOFSD_SOCKET" \
    --shared-dir="$SHARED_DIR" \
    --sandbox=none \
    --cache=never \
    --log-level=warn \
    &>"$VIRTIOFSD_LOG" &
  VIRTIOFSD_PID=$!

  for i in $(seq 1 20); do
    [ -S "$VIRTIOFSD_SOCKET" ] && break
    sleep 0.1
  done
  if [ ! -S "$VIRTIOFSD_SOCKET" ]; then
    echo "  ''${RED}FAILED: virtiofsd socket did not appear''${RESET}"
    cat "$VIRTIOFSD_LOG"
    exit 1
  fi
  echo "  ✓ virtiofsd started (PID: $VIRTIOFSD_PID)"

  # Start Cloud Hypervisor
  FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"
  ${cloudHypervisor}/bin/cloud-hypervisor \
    --firmware "$FIRMWARE" \
    --disk path="$IMAGE" \
    --cpus boot=2 \
    --memory size=1024M,shared=on \
    --fs tag=shared,socket="$VIRTIOFSD_SOCKET",num_queues=1,queue_size=512 \
    --serial file="$SERIAL_LOG" \
    --console off \
    &>"$VMM_LOG" &
  VM_PID=$!
  echo "  ✓ Cloud Hypervisor started (PID: $VM_PID)"
  echo ""

  if [ "$VERBOSE" = "1" ]; then
    tail -f "$SERIAL_LOG" 2>/dev/null &
    TAIL_PID=$!
  fi

  # ================================================================
  # Phase 2: Monitor boot + start build-bridge when guest is ready
  # ================================================================
  echo "  ''${CYAN}Phase 2: Monitor boot + test execution''${RESET}"

  M_BOOTLOADER=0
  M_KERNEL=0
  M_BOOT=0
  TESTS_STARTED=0
  TESTS_COMPLETE=0
  BRIDGE_STARTED=0
  LAST_PARSED_LINE=0

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

    # Boot milestones
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
    fi

    # Track test start
    if [ "$TESTS_STARTED" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "FUNC_TESTS_START"; then
      TESTS_STARTED=1
    fi

    # Parse FUNC_TEST lines incrementally
    if [ "$TESTS_STARTED" = "1" ]; then
      CURRENT_LINES=$(echo "$LOG_CONTENT" | tr -d '\r' | ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:" 2>/dev/null | wc -l)
      if [ "$CURRENT_LINES" -gt "$LAST_PARSED_LINE" ]; then
        echo "$LOG_CONTENT" | tr -d '\r' | ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:" 2>/dev/null | tail -n +"$((LAST_PARSED_LINE + 1))" | while IFS=: read -r _marker name result reason; do
          case "$result" in
            PASS) echo "    ''${GREEN}✓''${RESET} $name" ;;
            FAIL) echo "    ''${RED}✗''${RESET} $name: $reason" ;;
            SKIP) echo "    ''${YELLOW}⊘''${RESET} $name (skipped)" ;;
          esac
        done
        LAST_PARSED_LINE=$CURRENT_LINES
      fi
    fi

    # Start the REAL build-bridge daemon when guest signals ready
    if [ "$BRIDGE_STARTED" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "BRIDGE_REBUILD_READY"; then
      BRIDGE_STARTED=1
      echo ""
      echo "  ''${BLUE}→ Guest ready — starting REAL build-bridge daemon...''${RESET}"

      # Start the daemon in background
      REDOX_SHARED_DIR="$SHARED_DIR" \
      REDOX_FLAKE_DIR="$FLAKE_DIR" \
      REDOX_PROFILE="default" \
      POLL_INTERVAL=1 \
      ${buildBridge}/bin/redox-build-bridge &>"$BRIDGE_LOG" &
      BRIDGE_PID=$!
      echo "  ''${BLUE}→ build-bridge daemon started (PID: $BRIDGE_PID)''${RESET}"
      echo ""
    fi

    # Check if daemon died unexpectedly
    if [ "$BRIDGE_STARTED" = "1" ] && [ -n "$BRIDGE_PID" ]; then
      if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        echo ""
        echo "  ''${RED}WARNING: build-bridge daemon died!''${RESET}"
        echo "  Last 20 lines of bridge log:"
        tail -20 "$BRIDGE_LOG" 2>/dev/null | sed 's/^/    /'
        echo ""
        BRIDGE_PID=""
      fi
    fi

    # Done?
    if [ "$TESTS_COMPLETE" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "FUNC_TESTS_COMPLETE"; then
      TESTS_COMPLETE=1
      break
    fi

    sleep 0.1
  done

  # Stop verbose tail
  if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
    kill "$TAIL_PID" 2>/dev/null || true
  fi

  FINAL_MS=$(( $(ms_now) - START_MS ))

  # ================================================================
  # Results
  # ================================================================
  PASS_COUNT=0
  FAIL_COUNT=0
  SKIP_COUNT=0
  if [ -f "$SERIAL_LOG" ]; then
    PASS_COUNT=$(${pkgs.gnugrep}/bin/grep -c "^FUNC_TEST:.*:PASS" "$SERIAL_LOG" 2>/dev/null) || PASS_COUNT=0
    FAIL_COUNT=$(${pkgs.gnugrep}/bin/grep -c "^FUNC_TEST:.*:FAIL" "$SERIAL_LOG" 2>/dev/null) || FAIL_COUNT=0
    SKIP_COUNT=$(${pkgs.gnugrep}/bin/grep -c "^FUNC_TEST:.*:SKIP" "$SERIAL_LOG" 2>/dev/null) || SKIP_COUNT=0
  fi
  TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

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

  # Show bridge daemon log if there were failures
  if [ "$FAIL_COUNT" -gt 0 ] || [ "$TESTS_COMPLETE" = "0" ]; then
    if [ -s "$BRIDGE_LOG" ]; then
      echo "  ''${YELLOW}Build-bridge daemon log:''${RESET}"
      echo "  ────────────────────────────────────────"
      cat "$BRIDGE_LOG" 2>/dev/null | sed 's/^/  /'
      echo "  ────────────────────────────────────────"
      echo ""
    fi
  fi

  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  ''${RED}Failed tests:''${RESET}"
    ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:.*:FAIL" "$SERIAL_LOG" 2>/dev/null | tr -d '\r' | while IFS=: read -r _marker name _fail reason; do
      echo "    ✗ $name: $reason"
    done
    echo ""
  fi

  if [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" = "0" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     ''${GREEN}BRIDGE REBUILD TEST PASSED''${RESET}               ║"
    echo "  ╚══════════════════════════════════════════════╝"
    exit 0
  elif [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     ''${RED}BRIDGE REBUILD TEST FAILED''${RESET}               ║"
    echo "  ║     $FAIL_COUNT of $TOTAL_COUNT tests failed                    ║"
    echo "  ╚══════════════════════════════════════════════╝"
    exit 1
  elif [ "$M_BOOT" = "0" ]; then
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     ''${RED}BOOT FAILED''${RESET}                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
    echo "  Last 40 lines of serial output:"
    tail -40 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
    if [ -s "$VMM_LOG" ]; then
      echo "  VMM output:"
      cat "$VMM_LOG" | sed 's/^/  /'
    fi
    exit 1
  else
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     ''${RED}TESTS DID NOT COMPLETE''${RESET}                   ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
    echo "  Last 40 lines of serial output:"
    tail -40 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
    if [ -s "$BRIDGE_LOG" ]; then
      echo ""
      echo "  Build-bridge log:"
      cat "$BRIDGE_LOG" 2>/dev/null | sed 's/^/  /'
    fi
    exit 1
  fi
''
