# Automated bridge test for RedoxOS
#
# Tests the full build bridge: host pushes packages to shared directory,
# guest snix installs them via virtio-fs. Two phases:
#   Phase 1: Pre-populate cache with ripgrep+fd → boot → guest installs
#   Phase 2: Live push bat while VM running → guest detects and installs
#
# Uses the same test protocol as functional-test (FUNC_TEST:name:PASS/FAIL).
# Requires KVM (Cloud Hypervisor + virtio-fs).

{
  pkgs,
  lib,
  diskImage,
  # The push-to-redox tool (builds and serializes packages)
  pushToRedox,
  # Flake self reference for building packages
  flakeDir ? null,
}:

let
  cloudHypervisor = pkgs.cloud-hypervisor;
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;
  python = pkgs.python3;
in
pkgs.writeShellScriptBin "bridge-test" ''
    set -uo pipefail

    TIMEOUT="''${BRIDGE_TEST_TIMEOUT:-180}"
    VERBOSE=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --help)
          echo "Usage: bridge-test [--timeout SEC] [--verbose]"
          echo "  Tests the build bridge: host pushes packages, guest installs via virtio-fs"
          exit 0
          ;;
        *) echo "Unknown option: $1"; exit 1 ;;
      esac
    done

    # Require KVM
    if [ ! -w /dev/kvm ]; then
      echo "ERROR: /dev/kvm not available. Bridge test requires KVM for Cloud Hypervisor."
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
    VIRTIOFSD_SOCKET="$WORK_DIR/virtiofsd.sock"
    IMAGE="$WORK_DIR/redox.img"
    VM_PID=""
    VIRTIOFSD_PID=""
    TAIL_PID=""

    cleanup() {
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

    mkdir -p "$SHARED_DIR/cache"
    touch "$SERIAL_LOG"

    echo ""
    echo "  ''${BOLD}Redox OS Build Bridge Test''${RESET}"
    echo "  =========================="
    echo "  Timeout: ''${TIMEOUT}s"
    echo ""

    # Timing helper
    ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
    fmt_ms() { local ms=$1; echo "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))s"; }
    START_MS=$(ms_now)

    # ================================================================
    # Phase 1: Pre-populate shared cache with ripgrep + fd
    # ================================================================
    echo "  ''${CYAN}Phase 1: Pre-populate shared cache''${RESET}"

    # Use push-to-redox to build and serialize ripgrep + fd
    export REDOX_SHARED_DIR="$SHARED_DIR"
    ${pushToRedox}/bin/push-to-redox ripgrep fd 2>&1 | sed 's/^/    /'
    PUSH_EXIT=$?

    if [ "$PUSH_EXIT" -ne 0 ]; then
      echo ""
      echo "  ''${RED}FAILED: push-to-redox exited with $PUSH_EXIT''${RESET}"
      exit 1
    fi

    # Verify cache was created
    if [ ! -f "$SHARED_DIR/cache/packages.json" ]; then
      echo "  ''${RED}FAILED: packages.json not created''${RESET}"
      exit 1
    fi

    PKG_COUNT=$(${python}/bin/python3 -c "import json; d=json.load(open('$SHARED_DIR/cache/packages.json')); print(len(d['packages']))")
    echo ""
    echo "  ✓ Pre-populated cache with $PKG_COUNT packages"
    echo "    $(ls -1 "$SHARED_DIR/cache/"*.narinfo 2>/dev/null | wc -l) narinfo files"
    echo "    $(ls -1 "$SHARED_DIR/cache/nar/"*.nar.zst 2>/dev/null | wc -l) NAR files"
    echo ""

    # ================================================================
    # Phase 2: Start virtiofsd + Cloud Hypervisor
    # ================================================================
    echo "  ''${CYAN}Phase 2: Boot VM with virtio-fs''${RESET}"

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

    # Wait for socket
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

    # Start Cloud Hypervisor with virtio-fs
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
    # Phase 3: Watch for boot + test results + live push trigger
    # ================================================================
    echo "  ''${CYAN}Phase 3: Monitor test execution''${RESET}"

    M_BOOTLOADER=0
    M_KERNEL=0
    M_BOOT=0
    TESTS_STARTED=0
    TESTS_COMPLETE=0
    LIVE_PUSH_DONE=0
    BRIDGE_MOCK_DONE=0
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

      # Live push trigger: guest says it's ready, host pushes bat
      if [ "$LIVE_PUSH_DONE" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "BRIDGE_READY_FOR_LIVE_PUSH"; then
        LIVE_PUSH_DONE=1
        echo ""
        echo "  ''${BLUE}→ Guest ready for live push — pushing bat...''${RESET}"
        REDOX_SHARED_DIR="$SHARED_DIR" ${pushToRedox}/bin/push-to-redox bat 2>&1 | sed 's/^/    /'
        echo "  ''${BLUE}→ bat pushed to shared cache''${RESET}"
        echo ""
      fi

      # Bridge rebuild mock daemon: guest signals ready, host generates mock response
      # The guest writes a request to $SHARED_DIR/requests/rebuild-*.json
      # We create a mock response with the current manifest + hostname override
      if [ "$BRIDGE_MOCK_DONE" = "0" ] && echo "$LOG_CONTENT" | ${pkgs.gnugrep}/bin/grep -q "BRIDGE_REBUILD_READY"; then
        BRIDGE_MOCK_DONE=1
        echo ""
        echo "  ''${BLUE}→ Guest ready for bridge rebuild — starting mock daemon...''${RESET}"

        # Poll for the request file (guest writes it after the signal)
        for poll_i in $(seq 1 60); do
          REQ_FILE=$(ls "$SHARED_DIR"/requests/rebuild-*.json 2>/dev/null | head -1)
          if [ -n "$REQ_FILE" ] && [ -f "$REQ_FILE" ]; then
            break
          fi
          sleep 0.5
        done

        if [ -n "$REQ_FILE" ] && [ -f "$REQ_FILE" ]; then
          REQ_ID=$(basename "$REQ_FILE" .json)
          echo "  ''${BLUE}→ Found request: $REQ_ID''${RESET}"

          # Generate mock response: take the CURRENT manifest from the disk image,
          # override hostname with the value from the request config
          ${python}/bin/python3 << MOCK_EOF
  import json, os, sys, traceback

  try:
      # Read the request
      with open('$REQ_FILE') as f:
          req = json.load(f)
      config = req.get('config', {}) or {}
      req_id = req.get('requestId', '$REQ_ID')

      # Read the current manifest from the built disk image rootTree
      manifest_path = None
      for root, dirs, files in os.walk('${diskImage}'):
          for fn in files:
              if fn == 'manifest.json' and 'redox-system' in root:
                  manifest_path = os.path.join(root, fn)
                  break

      if manifest_path:
          with open(manifest_path) as f:
              manifest = json.load(f)
      else:
          # Fallback: minimal manifest
          manifest = {
              'manifestVersion': 1,
              'system': {
                  'redoxSystemVersion': '0.5.0',
                  'target': 'x86_64-unknown-redox',
                  'profile': 'development',
                  'hostname': 'redox',
                  'timezone': 'UTC'
              },
              'configuration': {
                  'boot': {'diskSizeMB': 768, 'espSizeMB': 200},
                  'hardware': {'storageDrivers': [], 'networkDrivers': [],
                      'graphicsDrivers': [], 'audioDrivers': [], 'usbEnabled': False},
                  'networking': {'enabled': True, 'mode': 'auto', 'dns': []},
                  'graphics': {'enabled': False, 'resolution': '1024x768'},
                  'security': {'protectKernelSchemes': True, 'requirePasswords': False,
                      'allowRemoteRoot': False},
                  'logging': {'logLevel': 'info', 'kernelLogLevel': 'warn',
                      'logToFile': True, 'maxLogSizeMB': 10},
                  'power': {'acpiEnabled': True, 'powerAction': 'shutdown',
                      'rebootOnPanic': False}
              },
              'packages': [],
              'drivers': {'all': [], 'initfs': [], 'core': []},
              'users': {},
              'groups': {},
              'services': {'initScripts': [], 'startupScript': '/startup.sh'},
              'files': {}
          }

      # Apply config overrides to the manifest (defensively)
      if config.get('hostname'):
          manifest.setdefault('system', {})['hostname'] = config['hostname']
      if config.get('timezone'):
          manifest.setdefault('system', {})['timezone'] = config['timezone']
      net = config.get('networking')
      if isinstance(net, dict):
          manifest_net = manifest.get('configuration', {}).get('networking', {})
          if isinstance(manifest_net, dict):
              if 'mode' in net:
                  manifest_net['mode'] = net['mode']
              if 'enable' in net:
                  manifest_net['enabled'] = net['enable']

      # Write response
      resp_dir = os.path.join('$SHARED_DIR', 'responses')
      os.makedirs(resp_dir, exist_ok=True)
      resp_path = os.path.join(resp_dir, f'{req_id}.json')
      response = {
          'status': 'success',
          'requestId': req_id,
          'manifest': manifest,
          'buildTimeMs': 100
      }
      with open(resp_path, 'w') as f:
          json.dump(response, f, indent=2)
      os.chmod(resp_path, 0o644)

      print(f'  Mock response written: {resp_path}')
      print(f'  Hostname: {manifest.get("system", {}).get("hostname", "?")}')

      # Clean up request
      try:
          os.rename('$REQ_FILE', '$REQ_FILE' + '.done')
      except:
          pass

  except Exception as e:
      # On ANY error, still write an error response so guest doesn't hang
      traceback.print_exc()
      try:
          resp_dir = os.path.join('$SHARED_DIR', 'responses')
          os.makedirs(resp_dir, exist_ok=True)
          resp_path = os.path.join(resp_dir, '$REQ_ID.json')
          response = {
              'status': 'error',
              'requestId': '$REQ_ID',
              'error': str(e)
          }
          with open(resp_path, 'w') as f:
              json.dump(response, f, indent=2)
          os.chmod(resp_path, 0o644)
          print(f'  Error response written: {resp_path}')
      except:
          traceback.print_exc()
  MOCK_EOF
          echo "  ''${BLUE}→ Mock response sent''${RESET}"
          echo ""
        else
          echo "  ''${YELLOW}→ No rebuild request found (timeout)''${RESET}"
          echo ""
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

    if [ "$FAIL_COUNT" -gt 0 ]; then
      echo "  ''${RED}Failed tests:''${RESET}"
      ${pkgs.gnugrep}/bin/grep "^FUNC_TEST:.*:FAIL" "$SERIAL_LOG" 2>/dev/null | tr -d '\r' | while IFS=: read -r _marker name _fail reason; do
        echo "    ✗ $name: $reason"
      done
      echo ""
    fi

    if [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" = "0" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
      echo "  ╔══════════════════════════════════════════╗"
      echo "  ║       ''${GREEN}BRIDGE TESTS PASSED''${RESET}                ║"
      echo "  ╚══════════════════════════════════════════╝"
      exit 0
    elif [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" -gt 0 ]; then
      echo "  ╔══════════════════════════════════════════╗"
      echo "  ║       ''${RED}BRIDGE TESTS FAILED''${RESET}                ║"
      echo "  ║       $FAIL_COUNT of $TOTAL_COUNT tests failed                ║"
      echo "  ╚══════════════════════════════════════════╝"
      exit 1
    elif [ "$M_BOOT" = "0" ]; then
      echo "  ╔══════════════════════════════════════════╗"
      echo "  ║       ''${RED}BOOT FAILED''${RESET}                        ║"
      echo "  ╚══════════════════════════════════════════╝"
      echo ""
      echo "  Last 40 lines of serial output:"
      echo "  ────────────────────────────────────────"
      tail -40 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
      echo "  ────────────────────────────────────────"
      if [ -s "$VMM_LOG" ]; then
        echo "  VMM output:"
        cat "$VMM_LOG" | sed 's/^/  /'
      fi
      if [ -s "$VIRTIOFSD_LOG" ]; then
        echo "  virtiofsd output:"
        cat "$VIRTIOFSD_LOG" | sed 's/^/  /'
      fi
      exit 1
    else
      echo "  ╔══════════════════════════════════════════╗"
      echo "  ║       ''${RED}TESTS DID NOT COMPLETE''${RESET}             ║"
      echo "  ╚══════════════════════════════════════════╝"
      echo ""
      echo "  Last 40 lines of serial output:"
      echo "  ────────────────────────────────────────"
      tail -40 "$SERIAL_LOG" 2>/dev/null | sed 's/^/  /'
      echo "  ────────────────────────────────────────"
      if [ -s "$VIRTIOFSD_LOG" ]; then
        echo ""
        echo "  virtiofsd log (last 20 lines):"
        echo "  ────────────────────────────────────────"
        tail -20 "$VIRTIOFSD_LOG" 2>/dev/null | sed 's/^/  /'
        echo "  ────────────────────────────────────────"
      fi
      exit 1
    fi
''
