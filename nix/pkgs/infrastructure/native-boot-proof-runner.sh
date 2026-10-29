# Sourced only by the native rebuild proof runner. Ordinary tests retain the
# one-boot lifecycle. Every launch below starts firmware against the same IMAGE.
BOOT_INDEX=0
BOOT_NAMES=(seed native rollback)
HOST_RESULTS="$WORK_DIR/host-results.log"
RESULT_LOG="$WORK_DIR/combined-serial.log"
CAPTURE_LOG="$RESULT_LOG"
: > "$HOST_RESULTS"
: > "$RESULT_LOG"
declare -A EXPECTED
EXPECTED[seed:bootloader]="$PROOF_SEED_BOOTLOADER"
EXPECTED[seed:kernel]="$PROOF_SEED_KERNEL"
EXPECTED[seed:initfs]="$PROOF_SEED_INITFS"
PROOF_FAILED=0
TEST_PREFIX=FUNC_TEST
TESTS_COMPLETE=0
LAST_PARSED_LINE=0

proof_result() {
  printf 'FUNC_TEST:host_%s:%s%s\n' "$1" "$2" "${3:+:$3}" >> "$HOST_RESULTS"
  echo "  host $1: $2${3:+ ($3)}"
}

proof_fail() {
  proof_result "$1" FAIL "$2"
  PROOF_FAILED=1
  return 1
}

proof_collect() {
  : > "$RESULT_LOG"
  for boot in 0 1 2; do
    log="$WORK_DIR/boot-$boot-${BOOT_NAMES[$boot]}.serial.log"
    if [ -f "$log" ]; then
      tr -d '\000\r' < "$log" >> "$RESULT_LOG"
      printf '\n' >> "$RESULT_LOG"
    fi
  done
  cat "$HOST_RESULTS" >> "$RESULT_LOG"
}

proof_stop_vm() {
  if [ -n "$VM_PID" ]; then
    kill "$VM_PID" 2>/dev/null || true
    wait "$VM_PID" 2>/dev/null || true
    VM_PID=""
  fi
  for pid in "$TAIL_PID" "$MONITOR_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  TAIL_PID=""
  MONITOR_PID=""
  cp "$WORK_DIR/vmm.log" "$WORK_DIR/boot-$BOOT_INDEX-${BOOT_NAMES[$BOOT_INDEX]}.vmm.log"
}

proof_launch() {
  SERIAL_LOG="$WORK_DIR/boot-$BOOT_INDEX-${BOOT_NAMES[$BOOT_INDEX]}.serial.log"
  : > "$SERIAL_LOG"
  M_BOOTLOADER=0 M_KERNEL=0 M_BOOT=0 LAST_PARSED_LINE=0
  echo "  Firmware boot $BOOT_INDEX (${BOOT_NAMES[$BOOT_INDEX]})"
  launch_vm
  start_vm_monitor
  if [ "$VERBOSE" = 1 ]; then
    tail -f "$SERIAL_LOG" &
    TAIL_PID=$!
  fi
}

proof_freeze_expectations() {
  local component phase value count
  count=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" -c '^FUNC_EXPECT:' || true)
  [ "$count" = 6 ] || { proof_fail expectations "expected exactly six pre-reboot manifest identities, got $count"; return 1; }
  for phase in seed native; do
    for component in bootloader kernel initfs; do
      value=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" "^FUNC_EXPECT:$phase:$component:" | cut -d: -f4-)
      if [[ ! "$value" =~ ^/nix/store/[a-z0-9]{32}-[^/:[:space:]]+$ ]]; then
        proof_fail expectations "invalid or duplicate $phase $component identity"
        return 1
      fi
      if [ "$phase" = seed ]; then
        [ "$value" = "${EXPECTED[seed:$component]}" ] || { proof_fail expectations "seed $component does not match configured seed derivation"; return 1; }
      else
        [ "$value" != "${EXPECTED[seed:$component]}" ] || { proof_fail expectations "native $component is the seed artifact"; return 1; }
        EXPECTED[native:$component]="$value"
      fi
    done
  done
  printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" '^FUNC_EXPECT:' > "$WORK_DIR/expected-identities.log"
  proof_result frozen_manifest_identities PASS
}

proof_validate_runtime() {
  local phase="$1" component actual count
  for component in bootloader kernel initfs; do
    count=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" -c "^BOOT_PROOF:$component:" || true)
    actual=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" "^BOOT_PROOF:$component:" | cut -d: -f3-)
    if [ "$count" != 1 ] || [ "$actual" != "${EXPECTED[$phase:$component]}" ]; then
      proof_fail "boot_${BOOT_INDEX}_${component}_identity" "expected ${EXPECTED[$phase:$component]}, observed $actual ($count markers)"
      return 1
    fi
    proof_result "boot_${BOOT_INDEX}_${component}_identity" PASS
  done
}

# Partition locations come from this disk's GPT, not a fixed image-size guess.
PARTITIONS=$("$PROOF_SFDISK" --json "$IMAGE") || exit 1
SECTOR_SIZE=$(printf '%s\n' "$PARTITIONS" | "$PROOF_JQ" -er '.partitiontable.sectorsize') || exit 1
ESP_START=$(printf '%s\n' "$PARTITIONS" | "$PROOF_JQ" -er '.partitiontable.partitions[] | select(.name == "ESP") | .start') || exit 1
ROOT_START=$(printf '%s\n' "$PARTITIONS" | "$PROOF_JQ" -er '.partitiontable.partitions[] | select(.name == "RedoxFS") | .start') || exit 1
ROOT_SIZE=$(printf '%s\n' "$PARTITIONS" | "$PROOF_JQ" -er '.partitiontable.partitions[] | select(.name == "RedoxFS") | .size') || exit 1

if [ -n "$STOP_AFTER_SCRIPT" ]; then
  proof_fail protocol '--stop-after-script cannot bypass the three-boot proof' || true
  proof_collect
  exit 1
fi

START_MS=$(ms_now)
proof_launch
while true; do
  ELAPSED_MS=$(( $(ms_now) - START_MS ))
  if [ "$((ELAPSED_MS / 1000))" -ge "$TIMEOUT" ]; then
    proof_fail protocol "three-boot proof timed out on boot $BOOT_INDEX" || true
    break
  fi

  # Ignore an incomplete final serial line until its newline is committed.
  LOG_CONTENT=$("$PROOF_PYTHON" - "$SERIAL_LOG" <<'PY'
import sys
with open(sys.argv[1], 'rb') as log:
    data = log.read().replace(b'\0', b'').replace(b'\r', b'')
end = data.rfind(b'\n')
if end >= 0:
    sys.stdout.buffer.write(data[:end + 1])
PY
)
  check_boot_milestones "$LOG_CONTENT" "$ELAPSED_MS"
  parse_test_lines "$LOG_CONTENT" FUNC_TEST
  if "$PROOF_GREP" -q '^FUNC_TEST:[^:]*:FAIL\(:\|$\)' <<< "$LOG_CONTENT"; then
    proof_fail protocol "guest assertion failed on boot $BOOT_INDEX; refusing restart/completion" || true
    break
  fi

  REBOOT_COUNT=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" -c '^FUNC_REBOOT:' || true)
  COMPLETE_COUNT=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" -c '^FUNC_TESTS_COMPLETE$' || true)
  if [ "$COMPLETE_COUNT" != 0 ]; then
    if [ "$BOOT_INDEX" != 2 ] || [ "$REBOOT_COUNT" != 0 ] || [ "$COMPLETE_COUNT" != 1 ]; then
      proof_fail protocol 'early completion, duplicate completion, or unexpected final reboot' || true
      break
    fi
    proof_validate_runtime seed || break
    TESTS_COMPLETE=1
    proof_result three_firmware_boots PASS
    break
  fi

  if [ "$REBOOT_COUNT" != 0 ]; then
    if [ "$BOOT_INDEX" -ge 2 ] || [ "$REBOOT_COUNT" != 1 ]; then
      proof_fail protocol 'unexpected or duplicate reboot request' || true
      break
    fi
    NEXT_PHASE="${BOOT_NAMES[$((BOOT_INDEX + 1))]}"
    REQUEST=$(printf '%s\n' "$LOG_CONTENT" | "$PROOF_GREP" '^FUNC_REBOOT:')
    EFI_PATH="${REQUEST#FUNC_REBOOT:$NEXT_PHASE:}"
    if [ "$REQUEST" = "$EFI_PATH" ]; then
      proof_fail protocol "expected $NEXT_PHASE reboot request" || true
      break
    fi
    if [ "$BOOT_INDEX" = 0 ]; then
      proof_freeze_expectations || break
      proof_validate_runtime seed || break
      NEXT_ID="${EXPECTED[native:bootloader]}"
    else
      proof_validate_runtime native || break
      NEXT_ID="${EXPECTED[seed:bootloader]}"
    fi
    if [ "$EFI_PATH" != "$NEXT_ID/boot/EFI/BOOT/BOOTX64.EFI" ]; then
      proof_fail protocol "EFI request is not the expected $NEXT_PHASE bootloader store file" || true
      break
    fi

    proof_stop_vm
    # Host-assisted ESP installation of the actual guest filesystem bytes. No
    # host build or serial transfer is involved, and the VMM holds no disk open.
    if ! "$PROOF_EXTRACT" "$IMAGE" "$((ROOT_START * SECTOR_SIZE))" "$((ROOT_SIZE * SECTOR_SIZE))" "$EFI_PATH" "$WORK_DIR/next.EFI"; then
      proof_fail esp_install "could not extract $EFI_PATH from the guest RedoxFS" || true
      break
    fi
    if ! "$PROOF_MCOPY" -o -i "$IMAGE@@$((ESP_START * SECTOR_SIZE))" "$WORK_DIR/next.EFI" ::/EFI/BOOT/BOOTX64.EFI; then
      proof_fail esp_install 'could not install extracted EFI into the disk ESP' || true
      break
    fi
    if ! sync "$IMAGE"; then
      proof_fail esp_install 'could not flush installed EFI to the disk' || true
      break
    fi
    proof_result "${NEXT_PHASE}_guest_efi_installed" PASS
    proof_collect
    BOOT_INDEX=$((BOOT_INDEX + 1))
    proof_launch
    continue
  fi

  if ! kill -0 "$VM_PID" 2>/dev/null; then
    proof_fail protocol "VMM exited without required reboot/completion on boot $BOOT_INDEX" || true
    break
  fi
  sleep 0.1
done
proof_stop_vm
proof_collect
FINAL_MS=$(( $(ms_now) - START_MS ))
count_results FUNC_TEST
if [ "$PROOF_FAILED" != 0 ]; then
  TESTS_COMPLETE=0
fi
report_test_results 'NATIVE THREE-BOOT PROOF PASSED' 'NATIVE THREE-BOOT PROOF FAILED'
show_failure_log 40
exit 1
