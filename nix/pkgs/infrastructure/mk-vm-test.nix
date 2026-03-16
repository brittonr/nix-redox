# Shared VM test runner infrastructure for RedoxOS
#
# Extracts common boilerplate from boot-test, functional-test, network-test:
#   - CLI arg parsing (--qemu, --ch, --timeout, --verbose)
#   - VMM auto-detection (KVM → Cloud Hypervisor, fallback → QEMU TCG)
#   - VM lifecycle (disk copy, launch, cleanup trap)
#   - Millisecond timing (ms_now, fmt_ms)
#   - Boot milestone polling (bootloader → kernel → boot complete)
#   - Test result parsing (FUNC_TEST / NET_TEST protocol)
#   - Result reporting with pass/fail boxes
#
# Usage:
#   vmTest = import ./mk-vm-test.nix { inherit pkgs lib; };
#   bootTest = vmTest.mkVmTest { name = "boot-test"; ... };

{ pkgs, lib }:

let
  cloudHypervisor = pkgs.cloud-hypervisor;
  cloudhvFirmware = pkgs.OVMF-cloud-hypervisor.fd;
  grep = "${pkgs.gnugrep}/bin/grep";
  sed = "${pkgs.gnused}/bin/sed";

  # Bash helper functions shared by all VM tests.
  bashLib = ''
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

    # === Millisecond timing ===
    ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
    fmt_ms() {
      local ms=$1
      echo "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))s"
    }

    # === Work directory + cleanup ===
    WORK_DIR=$(mktemp -d)
    VM_PID=""
    TAIL_PID=""
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

    SERIAL_LOG="$WORK_DIR/serial.log"
    touch "$SERIAL_LOG"

    # === Boot milestone check ===
    # Call inside polling loop. Sets M_BOOTLOADER, M_KERNEL, M_BOOT.
    check_boot_milestones() {
      local log="$1"
      local elapsed="$2"

      if [ "$M_BOOTLOADER" = "0" ] && echo "$log" | ${grep} -q "Redox OS Bootloader"; then
        M_BOOTLOADER=1
        echo "  ✓ [$(fmt_ms $elapsed)] Bootloader started"
      fi
      if [ "$M_KERNEL" = "0" ] && echo "$log" | ${grep} -q "Redox OS starting"; then
        M_KERNEL=1
        echo "  ✓ [$(fmt_ms $elapsed)] Kernel running"
      fi
      if [ "$M_BOOT" = "0" ] && echo "$log" | ${grep} -q "Boot Complete"; then
        M_BOOT=1
        echo "  ✓ [$(fmt_ms $elapsed)] Boot complete"
      fi
    }

    # === Test result parser ===
    # Parse PREFIX:name:PASS/FAIL/SKIP lines from serial log.
    # Tracks LAST_PARSED_LINE for incremental output.
    parse_test_lines() {
      local log="$1"
      local prefix="$2"

      CURRENT_LINES=$(echo "$log" | tr -d '\r' | ${grep} "^$prefix:" 2>/dev/null | wc -l)
      if [ "$CURRENT_LINES" -gt "$LAST_PARSED_LINE" ]; then
        echo "$log" | tr -d '\r' | ${grep} "^$prefix:" 2>/dev/null \
          | tail -n +"$((LAST_PARSED_LINE + 1))" \
          | while IFS=: read -r _marker name result reason; do
              # If filter is set, skip tests that don't match
              if [ -n "$TEST_FILTER" ] && ! echo "$name" | ${grep} -q "$TEST_FILTER"; then
                continue
              fi
              case "$result" in
                PASS) echo "    ''${GREEN}✓''${RESET} $name" ;;
                FAIL) echo "    ''${RED}✗''${RESET} $name: $reason" ;;
                SKIP) echo "    ''${YELLOW}⊘''${RESET} $name (skipped)" ;;
              esac
            done
        LAST_PARSED_LINE=$CURRENT_LINES
      fi
    }

    # === Count test results from serial log ===
    count_results() {
      local prefix="$1"
      if [ -n "$TEST_FILTER" ]; then
        # Filter and count matching tests
        PASS_COUNT=$(${grep} "^$prefix:.*:PASS" "$SERIAL_LOG" 2>/dev/null | while IFS=: read -r _marker name _result; do
          if echo "$name" | ${grep} -q "$TEST_FILTER"; then echo "$name"; fi
        done | wc -l) || PASS_COUNT=0
        FAIL_COUNT=$(${grep} "^$prefix:.*:FAIL" "$SERIAL_LOG" 2>/dev/null | while IFS=: read -r _marker name _result; do
          if echo "$name" | ${grep} -q "$TEST_FILTER"; then echo "$name"; fi
        done | wc -l) || FAIL_COUNT=0
        SKIP_COUNT=$(${grep} "^$prefix:.*:SKIP" "$SERIAL_LOG" 2>/dev/null | while IFS=: read -r _marker name _result; do
          if echo "$name" | ${grep} -q "$TEST_FILTER"; then echo "$name"; fi
        done | wc -l) || SKIP_COUNT=0
      else
        # Count all tests
        PASS_COUNT=$(${grep} -c "^$prefix:.*:PASS" "$SERIAL_LOG" 2>/dev/null) || PASS_COUNT=0
        FAIL_COUNT=$(${grep} -c "^$prefix:.*:FAIL" "$SERIAL_LOG" 2>/dev/null) || FAIL_COUNT=0
        SKIP_COUNT=$(${grep} -c "^$prefix:.*:SKIP" "$SERIAL_LOG" 2>/dev/null) || SKIP_COUNT=0
      fi
      TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    }

    # === Report test results ===
    report_test_results() {
      local pass_msg="$1"
      local fail_msg="$2"

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
        ${grep} "^$TEST_PREFIX:.*:FAIL" "$SERIAL_LOG" 2>/dev/null | tr -d '\r' \
          | while IFS=: read -r _marker name _fail reason; do
              # If filter is set, skip tests that don't match
              if [ -n "$TEST_FILTER" ] && ! echo "$name" | ${grep} -q "$TEST_FILTER"; then
                continue
              fi
              echo "    ✗ $name: $reason"
            done
        echo ""
      fi

      if [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" = "0" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║       ''${GREEN}$pass_msg''${RESET}"
        echo "  ╚══════════════════════════════════════════╝"
        exit 0
      elif [ "$TESTS_COMPLETE" = "1" ] && [ "$FAIL_COUNT" -gt 0 ]; then
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║       ''${RED}$fail_msg''${RESET}"
        echo "  ╚══════════════════════════════════════════╝"
        exit 1
      fi
    }

    # === Show serial log tail on failure ===
    show_failure_log() {
      local lines="''${1:-30}"
      echo ""
      echo "  Last $lines lines of serial output:"
      echo "  ────────────────────────────────────────"
      tail -"$lines" "$SERIAL_LOG" 2>/dev/null | ${sed} 's/^/  /'
      echo "  ────────────────────────────────────────"
      if [ -s "$WORK_DIR/vmm.log" ]; then
        echo ""
        echo "  VMM output:"
        echo "  ────────────────────────────────────────"
        cat "$WORK_DIR/vmm.log" | ${sed} 's/^/  /'
        echo "  ────────────────────────────────────────"
      fi
    }
  '';

  # Generate QEMU launch command.
  # Returns bash code that sets VM_PID.
  launchQemu =
    {
      bootloader,
      memoryMB ? 1024,
      cpus ? 2,
      extraArgs ? "",
    }:
    ''
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
        -m ${toString memoryMB} \
        -smp ${toString cpus} \
        $KVM_FLAGS \
        -serial file:"$SERIAL_LOG" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -bios "$OVMF" \
        -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
        -drive file="$IMAGE",format=raw,if=none,id=disk0 \
        -device virtio-blk-pci,drive=disk0 \
        -display none \
        -vga none \
        -no-reboot \
        ${extraArgs} \
        &>"$WORK_DIR/vmm.log" &
      VM_PID=$!
    '';

  # Generate Cloud Hypervisor launch command.
  # Returns bash code that sets VM_PID.
  launchCH =
    {
      memoryMB ? 1024,
      cpus ? 2,
      extraArgs ? "",
    }:
    ''
      FIRMWARE="${cloudhvFirmware}/FV/CLOUDHV.fd"
      ${cloudHypervisor}/bin/cloud-hypervisor \
        --firmware "$FIRMWARE" \
        --disk path="$IMAGE" \
        --cpus boot=${toString cpus} \
        --memory size=${toString memoryMB}M \
        --serial file="$SERIAL_LOG" \
        --console off \
        ${extraArgs} \
        &>"$WORK_DIR/vmm.log" &
      VM_PID=$!
    '';

in
{
  inherit bashLib launchQemu launchCH;

  # Build a complete VM test script.
  #
  # Parameters:
  #   name           - Script binary name
  #   title          - Display title
  #   diskImage      - Disk image derivation
  #   bootloader     - Bootloader derivation (for QEMU -kernel)
  #   defaultTimeout - Default timeout in seconds
  #   timeoutEnvVar  - Environment variable for timeout override
  #   memoryMB, cpus - VM resources
  #   defaultMode    - "auto", "qemu", or "ch"
  #   qemuExtraArgs  - Additional QEMU command line args
  #   chExtraArgs    - Additional Cloud Hypervisor args
  #   testPrefix     - "FUNC_TEST", "NET_TEST", or null (boot-only)
  #   trackShell     - Also track shell/login prompt (boot-test)
  #   extraPolling   - Bash code injected into the polling loop
  #   customReport   - Bash code that replaces the default result report
  mkVmTest =
    {
      name,
      title ? name,
      diskImage,
      bootloader,
      defaultTimeout ? 90,
      timeoutEnvVar ? "${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name)}_TIMEOUT",
      memoryMB ? 1024,
      cpus ? 2,
      defaultMode ? "auto",
      qemuExtraArgs ? "",
      chExtraArgs ? "",
      testPrefix ? null,
      trackShell ? false,
      extraPolling ? "",
      customReport ? null,
    }:
    let
      hasTests = testPrefix != null;
      startMarker = if hasTests then "${testPrefix}S_START" else null;
      completeMarker = if hasTests then "${testPrefix}S_COMPLETE" else null;
    in
    pkgs.writeShellScriptBin name ''
      set -uo pipefail

      # === Configuration ===
      TIMEOUT="''${${timeoutEnvVar}:-${toString defaultTimeout}}"
      MODE="${defaultMode}"
      VERBOSE=0
      TEST_FILTER=""

      usage() {
        echo "Usage: ${name} [OPTIONS]"
        echo ""
        echo "  ${title}"
        echo ""
        echo "Options:"
        echo "  --qemu         Force QEMU TCG mode (no KVM required)"
        echo "  --ch           Force Cloud Hypervisor mode (KVM required)"
        echo "  --timeout SEC  Set timeout (default: ${toString defaultTimeout}, env: ${timeoutEnvVar})"
        echo "  --filter PAT   Only run tests matching pattern (substring match)"
        echo "  --verbose      Show serial output in real time"
        echo "  --help         Show this help"
        exit 0
      }

      while [ $# -gt 0 ]; do
        case "$1" in
          --qemu)    MODE="qemu"; shift ;;
          --ch)      MODE="ch"; shift ;;
          --timeout) TIMEOUT="$2"; shift 2 ;;
          --filter)  TEST_FILTER="$2"; shift 2 ;;
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

      ${bashLib}

      # === Setup ===
      IMAGE="$WORK_DIR/redox.img"
      cp ${diskImage}/redox.img "$IMAGE"
      chmod +w "$IMAGE"

      echo ""
      echo "  ''${BOLD}${title}''${RESET}"
      echo "  $(printf '=%.0s' $(seq 1 ${toString (builtins.stringLength title + 4)}))"
      echo "  VMM:     $MODE"
      echo "  Timeout: ''${TIMEOUT}s"
      echo "  Image:   $(du -h "$IMAGE" | cut -f1)"
      echo ""

      # === Launch VM ===
      if [ "$MODE" = "ch" ]; then
        ${launchCH { inherit memoryMB cpus; extraArgs = chExtraArgs; }}
      else
        ${launchQemu { inherit bootloader memoryMB cpus; extraArgs = qemuExtraArgs; }}
      fi

      echo "  VM started (PID: $VM_PID)"
      echo ""

      if [ "$VERBOSE" = "1" ]; then
        tail -f "$SERIAL_LOG" 2>/dev/null &
        TAIL_PID=$!
      fi

      # === Polling loop ===
      M_BOOTLOADER=0
      M_KERNEL=0
      M_BOOT=0
      ${lib.optionalString trackShell "M_SHELL=0"}
      ${lib.optionalString hasTests ''
        TESTS_STARTED=0
        TESTS_COMPLETE=0
        LAST_PARSED_LINE=0
        TEST_PREFIX="${testPrefix}"
      ''}

      START_MS=$(ms_now)
      ${lib.optionalString hasTests ''echo "  ''${CYAN}Phase 1: Boot''${RESET}"''}

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
        check_boot_milestones "$LOG_CONTENT" "$ELAPSED_MS"

        ${lib.optionalString (hasTests) ''
          if [ "$M_BOOT" = "1" ] && [ "$TESTS_STARTED" = "0" ]; then
            echo ""
            echo "  ''${CYAN}Phase 2: Tests''${RESET}"
          fi
        ''}

        ${lib.optionalString trackShell ''
          if [ "$M_SHELL" = "0" ] && echo "$LOG_CONTENT" | ${grep} -qE "(ion>|Welcome to Redox)"; then
            M_SHELL=1
            echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Shell ready"
          fi
        ''}

        ${lib.optionalString hasTests ''
          # Track test start
          if [ "$TESTS_STARTED" = "0" ] && echo "$LOG_CONTENT" | ${grep} -q "${startMarker}"; then
            TESTS_STARTED=1
            echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Test suite started"
            echo ""
          fi

          # Parse test result lines incrementally
          if [ "$TESTS_STARTED" = "1" ]; then
            parse_test_lines "$LOG_CONTENT" "${testPrefix}"
          fi

          # Test completion
          if [ "$TESTS_COMPLETE" = "0" ] && echo "$LOG_CONTENT" | ${grep} -q "${completeMarker}"; then
            TESTS_COMPLETE=1
            echo ""
            echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Test suite complete"
            break
          fi
        ''}

        ${extraPolling}

        # Exit conditions for boot-only tests
        ${lib.optionalString (!hasTests && trackShell) ''
          if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "1" ]; then
            break
          fi
          if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "0" ]; then
            if [ -z "''${BOOT_MS:-}" ]; then BOOT_MS=$ELAPSED_MS; fi
            if [ "$(( (ELAPSED_MS - BOOT_MS) / 1000 ))" -ge 10 ]; then
              break
            fi
          fi
        ''}
        ${lib.optionalString (!hasTests && !trackShell) ''
          if [ "$M_BOOT" = "1" ]; then break; fi
        ''}

        sleep 0.1
      done

      # Stop verbose tail
      if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
      fi

      FINAL_MS=$(( $(ms_now) - START_MS ))

      # === Results ===
      ${
        if customReport != null then
          customReport
        else if hasTests then
          ''
            count_results "${testPrefix}"
            report_test_results \
              "${lib.toUpper (builtins.replaceStrings [ "-" ] [ " " ] name)} PASSED              " \
              "${lib.toUpper (builtins.replaceStrings [ "-" ] [ " " ] name)} FAILED              "

            # If report_test_results didn't exit, boot or completion failed
            if [ "$M_BOOT" = "0" ]; then
              echo "  ╔══════════════════════════════════════════╗"
              echo "  ║       ''${RED}BOOT FAILED''${RESET}                        ║"
              echo "  ╚══════════════════════════════════════════╝"
              show_failure_log 30
              exit 1
            else
              echo "  ╔══════════════════════════════════════════╗"
              echo "  ║       ''${RED}TESTS DID NOT COMPLETE''${RESET}             ║"
              echo "  ╚══════════════════════════════════════════╝"
              show_failure_log 30
              exit 1
            fi
          ''
        else
          ''
            echo ""
            echo "  Milestones:"
            [ "$M_BOOTLOADER" = "1" ] && echo "    ✓ bootloader"  || echo "    ✗ bootloader"
            [ "$M_KERNEL" = "1" ]     && echo "    ✓ kernel"      || echo "    ✗ kernel"
            [ "$M_BOOT" = "1" ]       && echo "    ✓ boot"        || echo "    ✗ boot"
            ${lib.optionalString trackShell ''[ "$M_SHELL" = "1" ]      && echo "    ✓ shell"       || echo "    ✗ shell"''}
            echo ""
            echo "  Total time: $(fmt_ms $FINAL_MS)"
            echo ""

            ${
              if trackShell then
                ''
                  if [ "$M_BOOT" = "1" ] && [ "$M_SHELL" = "1" ]; then
                    echo "  ╔══════════════════════════════════════════╗"
                    echo "  ║            BOOT TEST PASSED              ║"
                    echo "  ╚══════════════════════════════════════════╝"
                    exit 0
                  elif [ "$M_BOOT" = "1" ]; then
                    echo "  ╔══════════════════════════════════════════╗"
                    echo "  ║     BOOT TEST PARTIAL (no shell)         ║"
                    echo "  ╚══════════════════════════════════════════╝"
                    show_failure_log 15
                    exit 1
                  else
                    echo "  ╔══════════════════════════════════════════╗"
                    echo "  ║            BOOT TEST FAILED              ║"
                    echo "  ╚══════════════════════════════════════════╝"
                    show_failure_log 30
                    exit 1
                  fi
                ''
              else
                ''
                  if [ "$M_BOOT" = "1" ]; then
                    echo "  ╔══════════════════════════════════════════╗"
                    echo "  ║            TEST PASSED                   ║"
                    echo "  ╚══════════════════════════════════════════╝"
                    exit 0
                  else
                    echo "  ╔══════════════════════════════════════════╗"
                    echo "  ║            TEST FAILED                   ║"
                    echo "  ╚══════════════════════════════════════════╝"
                    show_failure_log 30
                    exit 1
                  fi
                ''
            }
          ''
      }
    '';
}
