#!/nix/system/profile/bin/bash
set -e

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export CARGO_HOME=/root/.cargo
export CARGO_BUILD_JOBS=1
export CARGO_INCREMENTAL=0
export RAYON_NUM_THREADS=4
export RUST_BACKTRACE=1

artifact() {
  printf 'FUNC_ARTIFACT:%s:%s\n' "$1" "$2"
}

latest_progress() {
  local err_file="$1"
  local last=""
  if [ ! -f "$err_file" ]; then
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      *"Compiling "*|*"Finished "*|*"Running "*|*"warning:"*|*"error:"*|*"build complete"*)
        last="$line"
        ;;
    esac
  done < "$err_file"
  printf '%s' "$last"
}

run_snix_build() {
  local label="$1"
  local build_file="$2"
  local output_file="$3"
  local err_file="$4"
  local prefix="$5"

  rm -f "$output_file" "$err_file"
  : > "$output_file"
  : > "$err_file"

  /bin/snix build --no-sandbox --file "$build_file" > "$output_file" 2> "$err_file" &
  local build_pid=$!
  printf '[%s] started pid=%s heartbeat=60s\n' "$prefix" "$build_pid"

  local prev_err_bytes=-1
  local stalled_heartbeats=0
  local start_secs=$SECONDS

  while kill -0 "$build_pid" 2>/dev/null; do
    sleep 60
    if ! kill -0 "$build_pid" 2>/dev/null; then
      break
    fi

    local out_bytes err_bytes elapsed last
    out_bytes=$(wc -c < "$output_file" 2>/dev/null || echo 0)
    err_bytes=$(wc -c < "$err_file" 2>/dev/null || echo 0)
    if [ "$err_bytes" = "$prev_err_bytes" ]; then
      stalled_heartbeats=$((stalled_heartbeats + 1))
    else
      stalled_heartbeats=0
    fi
    prev_err_bytes="$err_bytes"
    elapsed=$((SECONDS - start_secs))
    last=$(latest_progress "$err_file")
    if [ -n "$last" ]; then
      printf '[%s] heartbeat elapsed=%ss stdout=%sB stderr=%sB stalled=%s last=%s\n' \
        "$prefix" "$elapsed" "$out_bytes" "$err_bytes" "$stalled_heartbeats" "$last"
    else
      printf '[%s] heartbeat elapsed=%ss stdout=%sB stderr=%sB stalled=%s\n' \
        "$prefix" "$elapsed" "$out_bytes" "$err_bytes" "$stalled_heartbeats"
    fi
  done

  wait "$build_pid"
}

record_pathinfo() {
  local name="$1"
  local store_path="$2"
  case "$store_path" in
    /nix/store/*)
      local base hash pathinfo
      base=${store_path#/nix/store/}
      hash=${base%%-*}
      pathinfo="/nix/var/snix/pathinfo/${hash}.json"
      if [ -f "$pathinfo" ]; then
        artifact "$name-pathinfo" "$pathinfo"
        echo "=== $name pathinfo ==="
        cat "$pathinfo"
        echo "=== end $name pathinfo ==="
      fi
      ;;
  esac
}

extract_generation_id() {
  local manifest="$1"
  sed -n '/"generation"[[:space:]]*:/,/^[[:space:]]*}/ s/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$manifest" \
    | head -1 \
    || true
}

extract_boot_path() {
  local manifest="$1"
  local field="$2"
  sed -n "/\"boot\"[[:space:]]*:/,/^[[:space:]]*}/ s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\\1/p" "$manifest" \
    | head -1 \
    || true
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

compare_files() {
  local left="$1"
  local right="$2"
  cmp -s "$left" "$right"
}

echo ""
echo "========================================"
echo "  RedoxOS Native Kernel Rebuild Test"
echo "========================================"
echo ""
echo "FUNC_TESTS_START"
echo ""

if [ -f /usr/src/native-kernel-rebuild/bundle-manifest.json ]; then
  echo "FUNC_TEST:bundle-manifest-present:PASS"
  artifact bundle-manifest /usr/src/native-kernel-rebuild/bundle-manifest.json
else
  echo "FUNC_TEST:bundle-manifest-present:FAIL:/usr/src/native-kernel-rebuild/bundle-manifest.json missing"
fi

if [ -f /usr/src/native-kernel-rebuild/kernel/build.nix ]; then
  echo "FUNC_TEST:kernel-build-file-present:PASS"
  artifact kernel-build-file /usr/src/native-kernel-rebuild/kernel/build.nix
else
  echo "FUNC_TEST:kernel-build-file-present:FAIL:/usr/src/native-kernel-rebuild/kernel/build.nix missing"
fi

if [ -f /usr/src/native-kernel-rebuild/bootloader/build.nix ]; then
  echo "FUNC_TEST:bootloader-build-file-present:PASS"
  artifact bootloader-build-file /usr/src/native-kernel-rebuild/bootloader/build.nix
else
  echo "FUNC_TEST:bootloader-build-file-present:FAIL:/usr/src/native-kernel-rebuild/bootloader/build.nix missing"
fi

if [ -f /usr/src/native-kernel-rebuild/rust-src/library/core/src/lib.rs ]; then
  echo "FUNC_TEST:rust-src-present:PASS"
  artifact rust-src /usr/src/native-kernel-rebuild/rust-src/library
else
  echo "FUNC_TEST:rust-src-present:FAIL:/usr/src/native-kernel-rebuild/rust-src/library missing"
fi

if [ -x /bin/snix ]; then
  echo "FUNC_TEST:snix-binary-present:PASS"
else
  echo "FUNC_TEST:snix-binary-present:FAIL:/bin/snix missing"
fi

if [ -x /nix/system/profile/bin/lld-wrapper ] && [ -x /nix/system/profile/bin/ld.lld ] && [ -x /nix/system/profile/bin/lld-link ] && [ -x /nix/system/profile/bin/llvm-objcopy ]; then
  echo "FUNC_TEST:linker-tools-present:PASS"
else
  echo "FUNC_TEST:linker-tools-present:FAIL:lld-wrapper, ld.lld, lld-link, or llvm-objcopy missing"
fi

echo "=== bundle manifest ==="
cat /usr/src/native-kernel-rebuild/bundle-manifest.json 2>/dev/null || true
echo "=== end bundle manifest ==="

kernel_build_ok=0
bootloader_build_ok=0
kernel_output=""
bootloader_output=""
kernel_artifact=""
bootloader_artifact=""

current_manifest=/etc/redox-system/manifest.json
original_generation_id=$(extract_generation_id "$current_manifest")
original_kernel_path=$(extract_boot_path "$current_manifest" kernel)
original_bootloader_path=$(extract_boot_path "$current_manifest" bootloader)
original_hostname=$(cat /etc/hostname 2>/dev/null || true)
proof_hostname="native-kernel-boot-proof"

echo "--- kernel native rebuild: snix build --file ---"
if run_snix_build \
  kernel \
  /usr/src/native-kernel-rebuild/kernel/build.nix \
  /tmp/kernel-rebuild-output \
  /tmp/kernel-rebuild-err \
  kernel-rebuild
then
  kernel_output=$(cat /tmp/kernel-rebuild-output 2>/dev/null || true)
  printf '%s\n' "$kernel_output" > /tmp/kernel-rebuild-output
  if [ -n "$kernel_output" ] && [ -f "$kernel_output/boot/kernel" ] && [ -f "$kernel_output/boot/kernel.sym" ]; then
    echo "FUNC_TEST:kernel-native-build:PASS"
    artifact kernel-store "$kernel_output"
    record_pathinfo kernel "$kernel_output"
    kernel_build_ok=1
    kernel_artifact="$kernel_output/boot/kernel"
  else
    echo "FUNC_TEST:kernel-native-build:FAIL:missing boot/kernel or boot/kernel.sym in $kernel_output"
    echo "=== kernel build stderr ==="
    cat /tmp/kernel-rebuild-err 2>/dev/null || true
    echo "=== end kernel build stderr ==="
  fi
else
  echo "FUNC_TEST:kernel-native-build:FAIL:snix build exited non-zero"
  echo "=== kernel build stderr ==="
  cat /tmp/kernel-rebuild-err 2>/dev/null || true
  echo "=== end kernel build stderr ==="
fi

echo "--- bootloader native rebuild: snix build --file ---"
if run_snix_build \
  bootloader \
  /usr/src/native-kernel-rebuild/bootloader/build.nix \
  /tmp/bootloader-rebuild-output \
  /tmp/bootloader-rebuild-err \
  bootloader-rebuild
then
  bootloader_output=$(cat /tmp/bootloader-rebuild-output 2>/dev/null || true)
  printf '%s\n' "$bootloader_output" > /tmp/bootloader-rebuild-output
  if [ -n "$bootloader_output" ] && [ -f "$bootloader_output/boot/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "FUNC_TEST:bootloader-native-build:PASS"
    artifact bootloader-store "$bootloader_output"
    record_pathinfo bootloader "$bootloader_output"
    bootloader_build_ok=1
    bootloader_artifact="$bootloader_output/boot/EFI/BOOT/BOOTX64.EFI"
  else
    echo "FUNC_TEST:bootloader-native-build:FAIL:missing boot/EFI/BOOT/BOOTX64.EFI in $bootloader_output"
    echo "=== bootloader build stderr ==="
    cat /tmp/bootloader-rebuild-err 2>/dev/null || true
    echo "=== end bootloader build stderr ==="
  fi
else
  echo "FUNC_TEST:bootloader-native-build:FAIL:snix build exited non-zero"
  echo "=== bootloader build stderr ==="
  cat /tmp/bootloader-rebuild-err 2>/dev/null || true
  echo "=== end bootloader build stderr ==="
fi

if [ "$kernel_build_ok" -eq 1 ] && [ "$bootloader_build_ok" -eq 1 ]; then
  boot_proof_manifest=/tmp/native-boot-proof-manifest.json
  cp "$current_manifest" "$boot_proof_manifest"
  escaped_kernel_path=$(escape_sed_replacement "$kernel_artifact")
  escaped_bootloader_path=$(escape_sed_replacement "$bootloader_artifact")
  escaped_proof_hostname=$(escape_sed_replacement "$proof_hostname")

  sed -i "0,/\"hostname\": \"[^\"]*\"/s//\"hostname\": \"$escaped_proof_hostname\"/" "$boot_proof_manifest"
  sed -i "0,/\"kernel\": \"[^\"]*\"/s//\"kernel\": \"$escaped_kernel_path\"/" "$boot_proof_manifest"
  sed -i "0,/\"bootloader\": \"[^\"]*\"/s//\"bootloader\": \"$escaped_bootloader_path\"/" "$boot_proof_manifest"

  artifact boot-proof-manifest "$boot_proof_manifest"

  echo "--- boot artifact staging proof: snix system switch ---"
  staged_generation_id=""
  staged_generation_manifest=""
  if /bin/snix system switch "$boot_proof_manifest" -D native-kernel-boot-proof > /tmp/boot-stage-switch-out 2> /tmp/boot-stage-switch-err; then
    staged_generation_id=$(extract_generation_id "$current_manifest")
    staged_generation_manifest="/etc/redox-system/generations/${staged_generation_id}/manifest.json"
    artifact staged-generation "$staged_generation_id"
    artifact boot-default-marker /etc/redox-system/boot-default
    if [ -n "$staged_generation_id" ] \
      && [ -f "$staged_generation_manifest" ] \
      && [ "$(extract_boot_path "$current_manifest" kernel)" = "$kernel_artifact" ] \
      && [ "$(extract_boot_path "$current_manifest" bootloader)" = "$bootloader_artifact" ] \
      && [ "$(extract_boot_path "$staged_generation_manifest" kernel)" = "$kernel_artifact" ] \
      && [ "$(extract_boot_path "$staged_generation_manifest" bootloader)" = "$bootloader_artifact" ] \
      && [ -f /etc/redox-system/boot-default ] \
      && [ "$(cat /etc/redox-system/boot-default 2>/dev/null || true)" = "$staged_generation_id" ] \
      && [ -e "/nix/var/snix/gcroots/gen-${staged_generation_id}-boot-kernel" ] \
      && [ -e "/nix/var/snix/gcroots/gen-${staged_generation_id}-boot-bootloader" ] \
      && compare_files "$kernel_artifact" /boot/kernel \
      && compare_files "$kernel_artifact" /usr/lib/boot/kernel \
      && [ "$(cat /etc/hostname 2>/dev/null || true)" = "$proof_hostname" ]
    then
      echo "FUNC_TEST:boot-artifacts-staged:PASS"
      artifact staged-generation-manifest "$staged_generation_manifest"
    else
      echo "FUNC_TEST:boot-artifacts-staged:FAIL:staged generation missing manifest/boot marker/gc roots or kernel copies"
      echo "=== boot stage switch stdout ==="
      cat /tmp/boot-stage-switch-out 2>/dev/null || true
      echo "=== end boot stage switch stdout ==="
      echo "=== boot stage switch stderr ==="
      cat /tmp/boot-stage-switch-err 2>/dev/null || true
      echo "=== end boot stage switch stderr ==="
      echo "DEBUG staged_generation_id=$staged_generation_id"
      echo "DEBUG staged_generation_manifest=$staged_generation_manifest"
      echo "DEBUG current_manifest_kernel=$(extract_boot_path "$current_manifest" kernel)"
      echo "DEBUG current_manifest_bootloader=$(extract_boot_path "$current_manifest" bootloader)"
      echo "DEBUG hostname=$(cat /etc/hostname 2>/dev/null || true)"
      ls -ld "/nix/var/snix/gcroots/gen-${staged_generation_id}-boot-kernel" 2>/dev/null || true
      ls -ld "/nix/var/snix/gcroots/gen-${staged_generation_id}-boot-bootloader" 2>/dev/null || true
      cmp -s "$kernel_artifact" /boot/kernel; echo "DEBUG cmp_boot_kernel=$?"
      cmp -s "$kernel_artifact" /usr/lib/boot/kernel; echo "DEBUG cmp_usr_lib_boot_kernel=$?"
      echo "=== staged manifest ==="
      cat "$current_manifest" 2>/dev/null || true
      echo "=== end staged manifest ==="
    fi
  else
    echo "FUNC_TEST:boot-artifacts-staged:FAIL:snix system switch exited non-zero"
    echo "=== boot stage switch stdout ==="
    cat /tmp/boot-stage-switch-out 2>/dev/null || true
    echo "=== end boot stage switch stdout ==="
    echo "=== boot stage switch stderr ==="
    cat /tmp/boot-stage-switch-err 2>/dev/null || true
    echo "=== end boot stage switch stderr ==="
  fi

  echo "--- boot selection smoke: switch-generation + boot + activate-boot ---"
  if [ -n "$staged_generation_id" ] && [ -n "$original_generation_id" ] && [ "$staged_generation_id" != "$original_generation_id" ]; then
    if /bin/snix system switch-generation "$original_generation_id" > /tmp/boot-smoke-return-out 2> /tmp/boot-smoke-return-err \
      && [ "$(cat /etc/hostname 2>/dev/null || true)" = "$original_hostname" ] \
      && [ "$(extract_boot_path "$current_manifest" kernel)" = "$original_kernel_path" ] \
      && [ "$(extract_boot_path "$current_manifest" bootloader)" = "$original_bootloader_path" ]
    then
      generation_count_before=$(ls /etc/redox-system/generations 2>/dev/null | wc -l)
      if /bin/snix system boot "$staged_generation_id" > /tmp/boot-smoke-boot-out 2> /tmp/boot-smoke-boot-err \
        && [ -f /etc/redox-system/boot-default ] \
        && [ "$(cat /etc/redox-system/boot-default 2>/dev/null || true)" = "$staged_generation_id" ] \
        && [ "$(cat /etc/hostname 2>/dev/null || true)" = "$original_hostname" ]
      then
        if /bin/snix system activate-boot --generation "$staged_generation_id" > /tmp/boot-smoke-activate-out 2> /tmp/boot-smoke-activate-err; then
          generation_count_after=$(ls /etc/redox-system/generations 2>/dev/null | wc -l)
          if [ "$generation_count_before" = "$generation_count_after" ] \
            && [ "$(cat /etc/hostname 2>/dev/null || true)" = "$proof_hostname" ] \
            && [ "$(extract_boot_path "$current_manifest" kernel)" = "$kernel_artifact" ] \
            && [ "$(extract_boot_path "$current_manifest" bootloader)" = "$bootloader_artifact" ] \
            && compare_files "$kernel_artifact" /boot/kernel \
            && compare_files "$kernel_artifact" /usr/lib/boot/kernel
          then
            echo "FUNC_TEST:boot-selection-smoke:PASS"
            artifact boot-selected-generation "$staged_generation_id"
          else
            echo "FUNC_TEST:boot-selection-smoke:FAIL:activate-boot did not restore staged boot generation"
            echo "=== boot smoke activate stdout ==="
            cat /tmp/boot-smoke-activate-out 2>/dev/null || true
            echo "=== end boot smoke activate stdout ==="
            echo "=== boot smoke activate stderr ==="
            cat /tmp/boot-smoke-activate-err 2>/dev/null || true
            echo "=== end boot smoke activate stderr ==="
            echo "=== current manifest after activate-boot ==="
            cat "$current_manifest" 2>/dev/null || true
            echo "=== end current manifest after activate-boot ==="
          fi
        else
          echo "FUNC_TEST:boot-selection-smoke:FAIL:snix system activate-boot exited non-zero"
          echo "=== boot smoke activate stdout ==="
          cat /tmp/boot-smoke-activate-out 2>/dev/null || true
          echo "=== end boot smoke activate stdout ==="
          echo "=== boot smoke activate stderr ==="
          cat /tmp/boot-smoke-activate-err 2>/dev/null || true
          echo "=== end boot smoke activate stderr ==="
        fi
      else
        echo "FUNC_TEST:boot-selection-smoke:FAIL:snix system boot did not stage next-boot generation cleanly"
        echo "=== boot smoke boot stdout ==="
        cat /tmp/boot-smoke-boot-out 2>/dev/null || true
        echo "=== end boot smoke boot stdout ==="
        echo "=== boot smoke boot stderr ==="
        cat /tmp/boot-smoke-boot-err 2>/dev/null || true
        echo "=== end boot smoke boot stderr ==="
      fi
    else
      echo "FUNC_TEST:boot-selection-smoke:FAIL:could not move live system away from staged generation before activate-boot"
      echo "=== boot smoke return stdout ==="
      cat /tmp/boot-smoke-return-out 2>/dev/null || true
      echo "=== end boot smoke return stdout ==="
      echo "=== boot smoke return stderr ==="
      cat /tmp/boot-smoke-return-err 2>/dev/null || true
      echo "=== end boot smoke return stderr ==="
      echo "DEBUG original_generation_id=$original_generation_id"
      echo "DEBUG original_hostname=$original_hostname"
      echo "DEBUG original_kernel_path=$original_kernel_path"
      echo "DEBUG original_bootloader_path=$original_bootloader_path"
      echo "DEBUG current_hostname=$(cat /etc/hostname 2>/dev/null || true)"
      echo "DEBUG current_manifest_kernel=$(extract_boot_path "$current_manifest" kernel)"
      echo "DEBUG current_manifest_bootloader=$(extract_boot_path "$current_manifest" bootloader)"
    fi
  else
    echo "FUNC_TEST:boot-selection-smoke:FAIL:staged or original generation id missing"
  fi
else
  echo "FUNC_TEST:boot-artifacts-staged:FAIL:kernel-native-build or bootloader-native-build prerequisite missing"
  echo "FUNC_TEST:boot-selection-smoke:FAIL:kernel-native-build or bootloader-native-build prerequisite missing"
fi

echo ""
echo "FUNC_TESTS_COMPLETE"
