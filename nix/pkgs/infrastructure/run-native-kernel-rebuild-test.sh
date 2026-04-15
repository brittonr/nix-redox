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

echo ""
echo "FUNC_TESTS_COMPLETE"
