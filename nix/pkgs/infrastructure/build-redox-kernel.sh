#!/nix/system/profile/bin/bash
# Builder script for rebuilding the Redox kernel on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out    — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/native-kernel-rebuild/kernel
#   Rust stdlib sources at /usr/src/native-kernel-rebuild/rust-src/library

set -e

extract_executable() {
  local json_file="$1"
  local target_name="$2"
  local line=""
  local match=""

  if [ ! -f "$json_file" ]; then
    return 1
  fi

  while IFS= read -r line; do
    case "$line" in
      *'"reason":"compiler-artifact"'*'"name":"'"$target_name"'"'*)
        match="$line"
        ;;
    esac
  done < "$json_file"

  case "$match" in
    *'"executable":"'*)
      match=${match#*\"executable\":\"}
      match=${match%%\"*}
      printf '%s' "$match"
      return 0
      ;;
  esac

  return 1
}

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR/home"
export CARGO_HOME="$TMPDIR/cargo-home"
export CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS=1
export RAYON_NUM_THREADS=4
export RUST_BACKTRACE=1
export AR=/nix/system/profile/bin/llvm-ar
export CC=/nix/system/profile/bin/cc
export RUST_SRC_PATH=/usr/src/native-kernel-rebuild/rust-src/library
export REDOX_KERNEL_USE_PREBUILT_TRAMPOLINE=1
export CARGO_TERM_PROGRESS_WHEN="${CARGO_TERM_PROGRESS_WHEN:-always}"
export CARGO_TERM_PROGRESS_WIDTH="${CARGO_TERM_PROGRESS_WIDTH:-80}"

kernel_dir=/usr/src/native-kernel-rebuild/kernel
linker_script="$kernel_dir/linkers/x86_64.ld"
kernel_linker_log="$TMPDIR/kernel-linker"
kernel_linker="$TMPDIR/kernel-linker-wrapper"
kernel_cargo_json="$TMPDIR/kernel-cargo.jsonl"

mkdir -p "$HOME" "$CARGO_HOME" "$CARGO_TARGET_DIR" "$out/boot"

if [ -f "$kernel_dir/.cargo/config.toml" ]; then
  mv "$kernel_dir/.cargo/config.toml" "$kernel_dir/.cargo/config.toml.bundle"
fi
cat > "$CARGO_HOME/config.toml" <<'CFG'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/usr/src/native-kernel-rebuild/kernel/vendor"

[net]
offline = true
CFG

cp /nix/system/profile/bin/bash "$kernel_linker"
cat > "$kernel_linker" <<EOF
#!/nix/system/profile/bin/bash
printf '%s\n' "\$@" > "$kernel_linker_log.args"
exec /nix/system/profile/bin/lld-wrapper "\$@" 2> "$kernel_linker_log.stderr"
EOF

# cargo -Z build-std looks for rust-src at $(rustc --print sysroot)/lib/rustlib/src/rust/library.
# The guest sysroot is read-only, so copy rustlib into TMPDIR and overlay rust-src there.
real_sysroot=$(/nix/system/profile/bin/rustc --print sysroot 2>/dev/null || echo /nix/system/profile)
custom_sysroot="$TMPDIR/sysroot"
mkdir -p "$custom_sysroot/lib/rustlib/src"
rustlib_path="$real_sysroot/lib/rustlib"
rustlib_meta=$(ls -ld "$rustlib_path")
case "$rustlib_meta" in
  *' -> '*) rustlib_src=${rustlib_meta##* -> } ;;
  *) rustlib_src="$rustlib_path" ;;
esac
cp -r "$rustlib_src/." "$custom_sysroot/lib/rustlib/"
rm -rf "$custom_sysroot/lib/rustlib/src/rust"
cp -r /usr/src/native-kernel-rebuild/rust-src "$custom_sysroot/lib/rustlib/src/rust"

echo "[build-redox-kernel] real_sysroot=$real_sysroot" >&2
echo "[build-redox-kernel] rustlib_src=$rustlib_src" >&2
echo "[build-redox-kernel] custom_sysroot=$custom_sysroot" >&2
echo "[build-redox-kernel] linker_script=$linker_script" >&2
echo "[build-redox-kernel] kernel_linker=$kernel_linker" >&2
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library" >&2 || true
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library/std" >&2 || true
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library/windows_targets" >&2 || true
ls -ld "$linker_script" >&2 || true
ls -ld /nix/system/profile/bin/lld-wrapper >&2 || true
ls -ld /nix/system/profile/bin/ld.lld >&2 || true

# Use RUSTC that reports custom sysroot so cargo's -Z build-std finds rust-src there.
# cp bash to get exec permission, then overwrite contents (keeps mode on Redox).
wrapper="$TMPDIR/rustc-sysroot"
cp /nix/system/profile/bin/bash "$wrapper"
printf '%s\n' '#!/nix/system/profile/bin/bash' "exec /nix/system/profile/bin/rustc --sysroot $custom_sysroot \"\$@\"" > "$wrapper"
export RUSTC="$wrapper"

if ! cargo metadata --manifest-path "$custom_sysroot/lib/rustlib/src/rust/library/Cargo.toml" --no-deps --format-version 1 >/tmp/kernel-rust-src-metadata.json 2>/tmp/kernel-rust-src-metadata.err; then
  echo "[build-redox-kernel] cargo metadata on custom rust-src workspace failed" >&2
  cat /tmp/kernel-rust-src-metadata.err >&2 || true
fi

cd "$kernel_dir"
if ! cargo metadata --manifest-path "$custom_sysroot/lib/rustlib/src/rust/library/Cargo.toml" --no-deps --format-version 1 >/tmp/kernel-rust-src-from-kernel-dir.json 2>/tmp/kernel-rust-src-from-kernel-dir.err; then
  echo "[build-redox-kernel] cargo metadata from kernel dir on custom rust-src workspace failed" >&2
  cat /tmp/kernel-rust-src-from-kernel-dir.err >&2 || true
fi

if ! cargo rustc \
  --message-format=json-render-diagnostics \
  --locked \
  --bin kernel \
  --manifest-path Cargo.toml \
  --target targets/x86_64-unknown-kernel.json \
  --release \
  -Z build-std=core,alloc \
  -Z build-std-features=compiler-builtins-mem \
  -- \
  -C linker="$kernel_linker" \
  -C link-arg=-T \
  -C link-arg="$linker_script" \
  -C link-arg=-z \
  -C link-arg=max-page-size=0x1000 \
  > "$kernel_cargo_json"
then
  echo "=== kernel linker args ===" >&2
  cat "$kernel_linker_log.args" >&2 || true
  echo "=== end kernel linker args ===" >&2
  echo "=== kernel linker stderr ===" >&2
  cat "$kernel_linker_log.stderr" >&2 || true
  echo "=== end kernel linker stderr ===" >&2
  exit 1
fi

kernel_bin=$(extract_executable "$kernel_cargo_json" kernel || true)
echo "[build-redox-kernel] kernel_bin=$kernel_bin" >&2

if [ -z "$kernel_bin" ] || [ ! -f "$kernel_bin" ]; then
  echo "[build-redox-kernel] kernel output not found" >&2
  echo "=== kernel cargo json ===" >&2
  cat "$kernel_cargo_json" >&2 || true
  echo "=== end kernel cargo json ===" >&2
  echo "=== kernel linker args ===" >&2
  cat "$kernel_linker_log.args" >&2 || true
  echo "=== end kernel linker args ===" >&2
  ls -ld "$CARGO_TARGET_DIR/x86_64-unknown-kernel/release" >&2 || true
  ls "$CARGO_TARGET_DIR/x86_64-unknown-kernel/release" >&2 || true
  ls "$CARGO_TARGET_DIR/x86_64-unknown-kernel/release/deps" >&2 || true
  exit 1
fi

/nix/system/profile/bin/llvm-objcopy --strip-debug "$kernel_bin" "$out/boot/kernel"
/nix/system/profile/bin/llvm-objcopy --only-keep-debug "$kernel_bin" "$out/boot/kernel.sym"
