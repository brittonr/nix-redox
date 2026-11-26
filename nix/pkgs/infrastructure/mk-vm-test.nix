# Shared VM test runner infrastructure for RedoxOS
#
# Extracts common boilerplate from boot-test, functional-test, network-test:
#   - Backend and explicit auto/kvm/tcg acceleration policy
#   - Shared policy with ordinary QEMU runners
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

  policy = builtins.readFile ./vm-policy.sh;
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
    ARTIFACT_DIR="''${REDOX_VM_ARTIFACTS_DIR:-''${REDOX_VM_MONITOR_DIR:-}}"
    if [ -z "$ARTIFACT_DIR" ]; then
      ARTIFACT_DIR=$(mktemp -d "''${TMPDIR:-/tmp}/redox-vm-artifacts.XXXXXX")
    fi
    mkdir -p "$ARTIFACT_DIR"
    echo "  Artifacts: $ARTIFACT_DIR"
    VM_PID=""
    TAIL_PID=""
    MONITOR_PID=""
    SERIAL_PID=""
    RUN_START_MS=$(ms_now)
    cleanup() {
      TEST_EXIT_STATUS=$?
      trap - EXIT
      VM_EXIT_STATUS=not-started
      if [ -n "''${VM_PID:-}" ]; then
        if kill -0 "$VM_PID" 2>/dev/null; then
          kill "$VM_PID" 2>/dev/null || true
        fi
        VM_EXIT_STATUS=0
        wait "$VM_PID" 2>/dev/null || VM_EXIT_STATUS=$?
      fi
      if [ -n "''${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
      fi
      if [ -n "''${MONITOR_PID:-}" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
      fi
      if [ -n "''${SERIAL_PID:-}" ]; then
        kill "$SERIAL_PID" 2>/dev/null || true
        wait "$SERIAL_PID" 2>/dev/null || true
      fi
      {
        echo "test_exit_status=$TEST_EXIT_STATUS"
        echo "vm_exit_status=$VM_EXIT_STATUS"
        echo "elapsed_ms=$(( $(ms_now) - RUN_START_MS ))"
        echo "bootloader=''${M_BOOTLOADER:-0}"
        echo "kernel=''${M_KERNEL:-0}"
        echo "boot=''${M_BOOT:-0}"
        echo "shell=''${M_SHELL:-0}"
      } > "$ARTIFACT_DIR/result.env"
      for capture in "$WORK_DIR"/*.log; do
        [ ! -f "$capture" ] || cp "$capture" "$ARTIFACT_DIR/"
      done
      if [ -n "''${REDOX_VM_MONITOR_DIR:-}" ]; then
        mkdir -p "$REDOX_VM_MONITOR_DIR"
        if [ -e "''${CAPTURE_LOG:-$SERIAL_LOG}" ]; then
          cp "''${CAPTURE_LOG:-$SERIAL_LOG}" "$REDOX_VM_MONITOR_DIR/serial.log"
        fi
        for capture in "$WORK_DIR"/boot-*.serial.log "$WORK_DIR"/boot-*.vmm.log "$WORK_DIR"/expected-identities.log; do
          if [ -f "$capture" ]; then
            cp "$capture" "$REDOX_VM_MONITOR_DIR/"
          fi
        done
        if [ -e "$WORK_DIR/vmm.log" ]; then
          cp "$WORK_DIR/vmm.log" "$REDOX_VM_MONITOR_DIR/vmm.log"
        fi
      fi
      rm -rf "$WORK_DIR"
      exit "$TEST_EXIT_STATUS"
    }
    trap cleanup EXIT

    SERIAL_LOG="$WORK_DIR/serial.log"
    RESULT_LOG="$SERIAL_LOG"
    touch "$SERIAL_LOG"

    record_vm_execution() {
      # argv.nul is lossless; command.sh retains the exact readable invocation.
      printf '%s\0' "''${VM_COMMAND[@]}" > "$ARTIFACT_DIR/argv.nul"
      printf '%q ' "''${VM_COMMAND[@]}" > "$ARTIFACT_DIR/command.sh"
      printf '\n' >> "$ARTIFACT_DIR/command.sh"
      "''${VM_COMMAND[0]}" --version > "$ARTIFACT_DIR/vmm-version.log" 2>&1 || return $?
      {
        echo "executable=''${VM_COMMAND[0]}"
        echo "requested_backend=$REQUESTED_MODE"
        echo "requested_acceleration=$REQUESTED_ACCEL"
        echo "backend=$MODE"
        echo "acceleration=$RESOLVED_ACCEL"
        echo "cpu=$CPU_MODEL"
        echo "cpus=$VCPUS"
        echo "machine=$MACHINE_TYPE"
        echo "memory_mb=$MEMORY_MB"
        echo "guest_image=$GUEST_IMAGE_SOURCE"
        echo "firmware=$FIRMWARE_SOURCE"
        echo "bootloader=$BOOTLOADER_SOURCE"
      } > "$ARTIFACT_DIR/machine.env"
      ${pkgs.coreutils}/bin/sha256sum "$GUEST_IMAGE_SOURCE" "$FIRMWARE_SOURCE" \
        ''${BOOTLOADER_SOURCE:+"$BOOTLOADER_SOURCE"} > "$ARTIFACT_DIR/identities.sha256"
    }
    start_vm_monitor() {
      if [ -z "''${REDOX_VM_MONITOR_DIR:-}" ]; then
        return 0
      fi

      mkdir -p "$REDOX_VM_MONITOR_DIR"
      MONITOR_LOG="$REDOX_VM_MONITOR_DIR/host-monitor.log"
      {
        echo "started_at=$(date --iso-8601=seconds) pid=$VM_PID serial=$SERIAL_LOG"
        while kill -0 "$VM_PID" 2>/dev/null; do
          ts=$(date --iso-8601=seconds)
          echo "[$ts]"
          ps -o pid,ppid,etime,%cpu,%mem,rss,vsz,stat,cmd -p "$VM_PID" || true
          if [ -r "/proc/$VM_PID/io" ]; then
            ${grep} -E "read_bytes|write_bytes|syscr|syscw" "/proc/$VM_PID/io" || true
          fi
          if [ -e "$SERIAL_LOG" ]; then
            stat -c "serial_mtime=%y serial_size=%s" "$SERIAL_LOG" || true
          fi
          echo
          sleep 60
        done
        echo "[$(date --iso-8601=seconds)] process exited"
      } >> "$MONITOR_LOG" &
      MONITOR_PID=$!
    }

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
      local result_log="''${RESULT_LOG:-$SERIAL_LOG}"
      if [ -n "$TEST_FILTER" ]; then
        # Filter and count matching tests
        PASS_COUNT=$(${grep} "^$prefix:.*:PASS" "$result_log" 2>/dev/null | while IFS=: read -r _marker name _result; do
          if echo "$name" | ${grep} -q "$TEST_FILTER"; then echo "$name"; fi
        done | wc -l) || PASS_COUNT=0
        FAIL_COUNT=$(${grep} "^$prefix:.*:FAIL" "$result_log" 2>/dev/null | while IFS=: read -r _marker name _result; do
          if echo "$name" | ${grep} -q "$TEST_FILTER"; then echo "$name"; fi
        done | wc -l) || FAIL_COUNT=0
        SKIP_COUNT=$(${grep} "^$prefix:.*:SKIP" "$result_log" 2>/dev/null | while IFS=: read -r _marker name _result; do
          if echo "$name" | ${grep} -q "$TEST_FILTER"; then echo "$name"; fi
        done | wc -l) || SKIP_COUNT=0
      else
        # Count all tests
        PASS_COUNT=$(${grep} -c "^$prefix:.*:PASS" "$result_log" 2>/dev/null) || PASS_COUNT=0
        FAIL_COUNT=$(${grep} -c "^$prefix:.*:FAIL" "$result_log" 2>/dev/null) || FAIL_COUNT=0
        SKIP_COUNT=$(${grep} -c "^$prefix:.*:SKIP" "$result_log" 2>/dev/null) || SKIP_COUNT=0
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
        local result_log="''${RESULT_LOG:-$SERIAL_LOG}"
        echo "  ''${RED}Failed tests:''${RESET}"
        ${grep} "^$TEST_PREFIX:.*:FAIL" "$result_log" 2>/dev/null | tr -d '\r' \
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
      machineType ? "pc",
      extraArgs ? "",
      shellProbe ? false,
      diskOnly ? false,
    }:
    ''
      OVMF="$WORK_DIR/OVMF.fd"
      cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
      chmod +w "$OVMF"

      MACHINE_TYPE=${lib.escapeShellArg machineType}
      MEMORY_MB=${toString memoryMB}
      FIRMWARE_SOURCE=${pkgs.OVMF.fd}/FV/OVMF.fd
      BOOTLOADER_SOURCE=${lib.escapeShellArg (if diskOnly then "" else "${bootloader}/boot/EFI/BOOT/BOOTX64.EFI")}
      QEMU_EXTRA_ARGS=( ${extraArgs} )
      redox_vm_validate_qemu_extra "''${QEMU_EXTRA_ARGS[@]}" || exit $?
      VM_COMMAND=(
        ${pkgs.qemu}/bin/qemu-system-x86_64
        -M "$MACHINE_TYPE"
        "''${QEMU_ACCEL_ARGS[@]}"
        -m "$MEMORY_MB"
        -smp "$VCPUS"
        ${if shellProbe then ''
          -chardev socket,id=serial0,path="$WORK_DIR/serial.sock",server=on,wait=on
          -serial chardev:serial0
        '' else ''-serial file:"$SERIAL_LOG"''}
        -device isa-debug-exit,iobase=0xf4,iosize=0x04
        -bios "$OVMF"
        ${lib.optionalString (!diskOnly) "-kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI"}
        -drive file="$IMAGE",format=raw,if=none,id=disk0${lib.optionalString diskOnly ",cache=writethrough"}
        -device virtio-blk-pci,drive=disk0
        -display none
        -vga none
        -no-reboot
        "''${QEMU_EXTRA_ARGS[@]}"
      )
      record_vm_execution || exit $?
      "''${VM_COMMAND[@]}" &>"$WORK_DIR/vmm.log" &
      VM_PID=$!
      ${lib.optionalString shellProbe ''
        mkfifo "$WORK_DIR/serial-input"
        exec {SERIAL_INPUT_FD}<>"$WORK_DIR/serial-input"
        (
          while [ ! -S "$WORK_DIR/serial.sock" ] && kill -0 "$VM_PID" 2>/dev/null; do sleep 0.05; done
          exec ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$WORK_DIR/serial.sock" \
            < "$WORK_DIR/serial-input" >> "$SERIAL_LOG" 2> "$WORK_DIR/serial-transport.log"
        ) &
        SERIAL_PID=$!
      ''}
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
      MACHINE_TYPE=cloud-hypervisor
      MEMORY_MB=${toString memoryMB}
      FIRMWARE_SOURCE="${cloudhvFirmware}/FV/CLOUDHV.fd"
      BOOTLOADER_SOURCE=""
      FIRMWARE="$FIRMWARE_SOURCE"
      VM_COMMAND=(
        ${cloudHypervisor}/bin/cloud-hypervisor
        --firmware "$FIRMWARE"
        --disk path="$IMAGE"
        --cpus boot="$VCPUS"
        --memory size=${toString memoryMB}M
        --serial file="$SERIAL_LOG"
        --console off
        ${extraArgs}
      )
      record_vm_execution || exit $?
      "''${VM_COMMAND[@]}" &>"$WORK_DIR/vmm.log" &
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
  #   enableQemu     - Include/support QEMU launch path in the runner
  #   enableCH       - Include/support Cloud Hypervisor launch path in the runner
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
      acceleration ? "auto",
      tcgCpus ? 1,
      machineType ? "pc",
      enableQemu ? true,
      enableCH ? true,
      qemuExtraArgs ? "",
      chExtraArgs ? "",
      testPrefix ? null,
      trackShell ? false,
      extraPolling ? "",
      customReport ? null,
      # Three firmware boots on the same mutable disk; null keeps ordinary tests unchanged.
      # { seedIdentities = { bootloader; kernel; initfs; }; }
      nativeBootProof ? null,
      # Minimum timeout floor for QEMU TCG fallback (no KVM).
      # Pulled from virtualisation.chMinTimeout when available.
      chMinTimeout ? 180,
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
      ${policy}
      redox_vm_policy_init ${lib.escapeShellArg defaultMode} ${lib.escapeShellArg acceleration} ${toString cpus} ${toString tcgCpus}
      VERBOSE=0
      TEST_FILTER=""
      STOP_AFTER_SCRIPT=""

      usage() {
        echo "Usage: ${name} [OPTIONS]"
        echo ""
        echo "  ${title}"
        echo ""
        echo "Options:"
        ${lib.optionalString enableQemu ''echo "  --qemu         Select QEMU; defaults to TCG unless --accel is supplied"''}
        ${lib.optionalString enableCH ''echo "  --ch           Select Cloud Hypervisor (KVM only)"''}
        echo "  --accel POLICY auto, kvm, tcg (CLI > --qemu shorthand > REDOX_VM_ACCEL > Nix)"
        echo "  --cpus N       Override vCPUs (TCG default: ${toString tcgCpus}; native: ${toString cpus})"
        echo "  --artifacts DIR Retain serial/VMM logs, command, identities and results"
        echo "  --timeout SEC  Set timeout (default: ${toString defaultTimeout}, env: ${timeoutEnvVar})"
        echo "  --filter PAT   Only report tests matching pattern (substring match)"
        echo "  --stop-after-script NAME"
        echo "                 Stop after script banner NAME completes"
        echo "  --verbose      Show serial output in real time"
        echo "  --help         Show this help"
        exit 0
      }

      while [ $# -gt 0 ]; do
        case "$1" in
          --qemu|--ch|--accel|--cpus)
            redox_vm_policy_option "$@" || exit $?
            shift "$POLICY_SHIFT" ;;
          --artifacts)
            [ $# -ge 2 ] || { echo "ERROR: --artifacts requires a directory" >&2; exit 2; }
            REDOX_VM_ARTIFACTS_DIR="$2"; shift 2 ;;
          --timeout) TIMEOUT="$2"; shift 2 ;;
          --filter)  TEST_FILTER="$2"; shift 2 ;;
          --stop-after-script) STOP_AFTER_SCRIPT="$2"; shift 2 ;;
          --verbose) VERBOSE=1; shift ;;
          --help)    usage ;;
          *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
      done

      redox_vm_policy_resolve ${if enableQemu then "1" else "0"} ${if enableCH then "1" else "0"} || exit $?
      if [ "$RESOLVED_ACCEL" = tcg ] && [ "$TIMEOUT" -lt ${toString chMinTimeout} ]; then
        TIMEOUT=${toString chMinTimeout}
      fi

      ${bashLib}

      # === Setup ===
      IMAGE="$WORK_DIR/redox.img"
      GUEST_IMAGE_SOURCE=${diskImage}/redox.img
      cp ${lib.optionalString (nativeBootProof != null) "--sparse=always"} ${diskImage}/redox.img "$IMAGE"
      chmod +w "$IMAGE"

      echo ""
      echo "  ''${BOLD}${title}''${RESET}"
      echo "  $(printf '=%.0s' $(seq 1 ${toString (builtins.stringLength title + 4)}))"
      echo "  VMM:     $MODE"
      echo "  Timeout: ''${TIMEOUT}s"
      echo "  Image:   $(du -h "$IMAGE" | cut -f1)"
      echo ""

      # === Launch VM (also reused by each cold firmware restart) ===
      launch_vm() {
      ${
        if enableCH && enableQemu then
          ''
            if [ "$MODE" = "ch" ]; then
              ${launchCH { inherit memoryMB cpus; extraArgs = chExtraArgs; }}
            else
              ${launchQemu { inherit bootloader memoryMB cpus machineType; shellProbe = trackShell; diskOnly = nativeBootProof != null; extraArgs = qemuExtraArgs; }}
            fi
          ''
        else if enableCH then
          launchCH { inherit memoryMB cpus; extraArgs = chExtraArgs; }
        else
          launchQemu { inherit bootloader memoryMB cpus machineType; shellProbe = trackShell; diskOnly = nativeBootProof != null; extraArgs = qemuExtraArgs; }
      }
      }

      ${lib.optionalString (nativeBootProof != null) ''
        PROOF_SEED_BOOTLOADER=${lib.escapeShellArg nativeBootProof.seedIdentities.bootloader}
        PROOF_SEED_KERNEL=${lib.escapeShellArg nativeBootProof.seedIdentities.kernel}
        PROOF_SEED_INITFS=${lib.escapeShellArg nativeBootProof.seedIdentities.initfs}
        PROOF_GREP=${grep}
        PROOF_PYTHON=${pkgs.python3}/bin/python3
        ${builtins.readFile ./native-boot-proof-runner.sh}
      ''}

      launch_vm

      echo "  VM started (PID: $VM_PID)"
      if [ -n "''${REDOX_VM_MONITOR_DIR:-}" ]; then
        echo "  Capture: $REDOX_VM_MONITOR_DIR"
      fi
      echo ""

      start_vm_monitor

      if [ "$VERBOSE" = "1" ]; then
        tail -f "$SERIAL_LOG" 2>/dev/null &
        TAIL_PID=$!
      fi

      # === Polling loop ===
      M_BOOTLOADER=0
      M_KERNEL=0
      M_BOOT=0
      ${lib.optionalString trackShell ''
        M_SHELL=0
        SHELL_MARKER="REDOX_VM_SHELL_READY_$$"
        LAST_SHELL_PROBE=-1
      ''}
      ${lib.optionalString hasTests ''
        TESTS_STARTED=0
        TESTS_COMPLETE=0
        LAST_PARSED_LINE=0
        TEST_PREFIX="${testPrefix}"
        CURRENT_SCRIPT=""
        LAST_SCRIPT_LINE=0
        STOP_AFTER_SCRIPT_SEEN=0
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

        LOG_CONTENT=$(${pkgs.coreutils}/bin/tr -d '\000' < "$SERIAL_LOG" 2>/dev/null || true)

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
          if [ "$MODE" = qemu ]; then
            if [ "$M_BOOT" = 1 ] && [ "$M_SHELL" = 0 ] && [ "$LAST_SHELL_PROBE" != "$ELAPSED_S" ] && [ -S "$WORK_DIR/serial.sock" ]; then
              LAST_SHELL_PROBE="$ELAPSED_S"
              # Require command output, not the banner or an echoed input line.
              printf 'echo; echo %s\n' "$SHELL_MARKER" >&"$SERIAL_INPUT_FD"
            fi
            if [ "$M_SHELL" = 0 ] && printf '%s\n' "$LOG_CONTENT" | tr -d '\r' | ${grep} -qxF "$SHELL_MARKER"; then
              M_SHELL=1
              echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Shell executed probe"
            fi
          elif [ "$M_SHELL" = 0 ] && echo "$LOG_CONTENT" | ${grep} -qE '(ion>|Welcome to Redox)'; then
            M_SHELL=1
            echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Shell/login prompt ready"
          fi
        ''}

        ${lib.optionalString hasTests ''
          # Track test start
          if [ "$TESTS_STARTED" = "0" ] && echo "$LOG_CONTENT" | ${grep} -q "${startMarker}"; then
            TESTS_STARTED=1
            echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Test suite started"
            echo ""
          fi

          PARSE_LOG_CONTENT="$LOG_CONTENT"
          STOP_AFTER_TRIGGERED=0
          STOP_AFTER_NEXT_SCRIPT=""

          if [ "$TESTS_STARTED" = "1" ]; then
            CURRENT_SCRIPT_LINES=$(echo "$LOG_CONTENT" | tr -d '\r' | ${grep} -- '--- .*\.ion ---' 2>/dev/null | wc -l)
            if [ "$CURRENT_SCRIPT_LINES" -gt "$LAST_SCRIPT_LINE" ]; then
              while IFS= read -r NEXT_SCRIPT; do
                if [ -n "$STOP_AFTER_SCRIPT" ] && [ "$STOP_AFTER_SCRIPT_SEEN" = "1" ] && [ "$CURRENT_SCRIPT" = "$STOP_AFTER_SCRIPT" ] && [ "$NEXT_SCRIPT" != "$CURRENT_SCRIPT" ]; then
                  TESTS_COMPLETE=1
                  STOP_AFTER_TRIGGERED=1
                  STOP_AFTER_NEXT_SCRIPT="$NEXT_SCRIPT"
                  break
                fi
                CURRENT_SCRIPT="$NEXT_SCRIPT"
                if [ -n "$STOP_AFTER_SCRIPT" ] && [ "$CURRENT_SCRIPT" = "$STOP_AFTER_SCRIPT" ]; then
                  STOP_AFTER_SCRIPT_SEEN=1
                fi
              done < <(
                echo "$LOG_CONTENT" | tr -d '\r' | ${grep} -- '--- .*\.ion ---' 2>/dev/null \
                  | tail -n +"$((LAST_SCRIPT_LINE + 1))" \
                  | ${sed} -e 's/^ *--- //' -e 's/ ---$//'
              )
              LAST_SCRIPT_LINE=$CURRENT_SCRIPT_LINES
              if [ "$STOP_AFTER_TRIGGERED" = "1" ] && [ -n "$STOP_AFTER_NEXT_SCRIPT" ]; then
                CUTOFF_LINE=$(printf '%s\n' "$LOG_CONTENT" | tr -d '\r' | ${grep} -nF -- "--- $STOP_AFTER_NEXT_SCRIPT ---" | head -n 1 | ${sed} 's/:.*//' || true)
                if [ -n "$CUTOFF_LINE" ] && [ "$CUTOFF_LINE" -gt 1 ] 2>/dev/null; then
                  PARSE_LOG_CONTENT=$(printf '%s\n' "$LOG_CONTENT" | tr -d '\r' | head -n "$((CUTOFF_LINE - 1))")
                else
                  PARSE_LOG_CONTENT=$(printf '%s\n' "$LOG_CONTENT" | tr -d '\r')
                fi
                RESULT_LOG="$WORK_DIR/result-serial.log"
                printf '%s\n' "$PARSE_LOG_CONTENT" > "$RESULT_LOG"
              fi
            fi
          fi

          # Parse test result lines incrementally
          if [ "$TESTS_STARTED" = "1" ]; then
            parse_test_lines "$PARSE_LOG_CONTENT" "${testPrefix}"
          fi

          if [ "$STOP_AFTER_TRIGGERED" = "1" ]; then
            echo ""
            echo "  ✓ [$(fmt_ms $ELAPSED_MS)] Stopped after script $STOP_AFTER_SCRIPT"
            break
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
