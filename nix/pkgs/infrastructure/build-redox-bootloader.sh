#!/nix/system/profile/bin/bash
# Builder script for rebuilding the Redox bootloader on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out    — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/native-kernel-rebuild/bootloader
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
export CARGO_TERM_PROGRESS_WHEN="${CARGO_TERM_PROGRESS_WHEN:-always}"
export CARGO_TERM_PROGRESS_WIDTH="${CARGO_TERM_PROGRESS_WIDTH:-80}"
export CARGO_TARGET_X86_64_UNKNOWN_UEFI_RUSTFLAGS="--cfg aes_force_soft"

bootloader_dir=/usr/src/native-kernel-rebuild/bootloader
bootloader_linker="$TMPDIR/bootloader-linker-wrapper"
bootloader_cargo_json="$TMPDIR/bootloader-cargo.jsonl"

mkdir -p "$HOME" "$CARGO_HOME" "$CARGO_TARGET_DIR" "$out/boot/EFI/BOOT"

if [ -f "$bootloader_dir/.cargo/config.toml" ]; then
  mv "$bootloader_dir/.cargo/config.toml" "$bootloader_dir/.cargo/config.toml.bundle"
fi
cat > "$CARGO_HOME/config.toml" <<'CFG'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/usr/src/native-kernel-rebuild/bootloader/vendor"

[net]
offline = true
CFG

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

rustc_meta=$(ls -ld /nix/system/profile/bin/rustc)
case "$rustc_meta" in
  *' -> '*) rustc_bin=${rustc_meta##* -> } ;;
  *) rustc_bin=/nix/system/profile/bin/rustc ;;
esac
manifest_toolchain_line=$(grep '"rust_toolchain_store":' /usr/src/native-kernel-rebuild/bundle-manifest.json || true)
manifest_toolchain_key='"rust_toolchain_store": "'
case "$manifest_toolchain_line" in
  *"$manifest_toolchain_key"*)
    rust_toolchain_root=${manifest_toolchain_line#*$manifest_toolchain_key}
    rust_toolchain_root=${rust_toolchain_root%%\"*}
    ;;
  *)
    rust_toolchain_root=${rustc_bin%/bin/rustc}
    ;;
esac

rust_lld=""
for candidate in "$rust_toolchain_root"/lib/rustlib/*/bin/rust-lld; do
  if [ -e "$candidate" ]; then
    rust_lld="$candidate"
    break
  fi
done

if [ -z "$rust_lld" ]; then
  echo "[build-redox-bootloader] rust-lld not found under $rust_toolchain_root/lib/rustlib/*/bin" >&2
  exit 1
fi

cp /nix/system/profile/bin/bash "$bootloader_linker"
cat > "$bootloader_linker" <<EOF
#!/nix/system/profile/bin/bash
export PI_LLD_REAL="$rust_lld"
exec /nix/system/profile/bin/lld-wrapper "\$@"
EOF

echo "[build-redox-bootloader] real_sysroot=$real_sysroot" >&2
echo "[build-redox-bootloader] rustlib_src=$rustlib_src" >&2
echo "[build-redox-bootloader] custom_sysroot=$custom_sysroot" >&2
echo "[build-redox-bootloader] rustc_bin=$rustc_bin" >&2
echo "[build-redox-bootloader] rust_toolchain_root=$rust_toolchain_root" >&2
echo "[build-redox-bootloader] rust_lld=$rust_lld" >&2
echo "[build-redox-bootloader] bootloader_linker=$bootloader_linker" >&2
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library" >&2 || true
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library/std" >&2 || true
ls -ld "$rust_lld" >&2 || true
ls -ld /nix/system/profile/bin/lld-wrapper >&2 || true
ls -ld /nix/system/profile/bin/ld.lld >&2 || true

wrapper="$TMPDIR/rustc-sysroot"
cp /nix/system/profile/bin/bash "$wrapper"
printf '%s\n' '#!/nix/system/profile/bin/bash' "exec /nix/system/profile/bin/rustc --sysroot $custom_sysroot \"\$@\"" > "$wrapper"
export RUSTC="$wrapper"

cd "$bootloader_dir"

if ! cargo rustc \
  --message-format=json-render-diagnostics \
  --bin bootloader \
  --manifest-path Cargo.toml \
  --target x86_64-unknown-uefi \
  --release \
  -Z build-std=core,alloc \
  -Z build-std-features=compiler-builtins-mem \
  -- \
  -C linker="$bootloader_linker" \
  > "$bootloader_cargo_json"
then
  exit 1
fi

bootloader_bin=$(extract_executable "$bootloader_cargo_json" bootloader || true)
echo "[build-redox-bootloader] bootloader_bin=$bootloader_bin" >&2

if [ -z "$bootloader_bin" ] || [ ! -f "$bootloader_bin" ]; then
  echo "[build-redox-bootloader] bootloader output not found" >&2
  echo "=== bootloader cargo json ===" >&2
  cat "$bootloader_cargo_json" >&2 || true
  echo "=== end bootloader cargo json ===" >&2
  ls -ld "$CARGO_TARGET_DIR/x86_64-unknown-uefi/release" >&2 || true
  ls "$CARGO_TARGET_DIR/x86_64-unknown-uefi/release" >&2 || true
  ls "$CARGO_TARGET_DIR/x86_64-unknown-uefi/release/deps" >&2 || true
  exit 1
fi

cp "$bootloader_bin" "$out/boot/EFI/BOOT/BOOTX64.EFI"
