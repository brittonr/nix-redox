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

mkdir -p "$HOME" "$CARGO_HOME" "$CARGO_TARGET_DIR" "$out/boot"

if [ -f /usr/src/native-kernel-rebuild/kernel/.cargo/config.toml ]; then
  mv /usr/src/native-kernel-rebuild/kernel/.cargo/config.toml /usr/src/native-kernel-rebuild/kernel/.cargo/config.toml.bundle
fi
cat > "$CARGO_HOME/config.toml" <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/usr/src/native-kernel-rebuild/kernel/vendor"

[net]
offline = true
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
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library" >&2 || true
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library/std" >&2 || true
ls -ld "$custom_sysroot/lib/rustlib/src/rust/library/windows_targets" >&2 || true

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

cd /usr/src/native-kernel-rebuild/kernel
if ! cargo metadata --manifest-path "$custom_sysroot/lib/rustlib/src/rust/library/Cargo.toml" --no-deps --format-version 1 >/tmp/kernel-rust-src-from-kernel-dir.json 2>/tmp/kernel-rust-src-from-kernel-dir.err; then
  echo "[build-redox-kernel] cargo metadata from kernel dir on custom rust-src workspace failed" >&2
  cat /tmp/kernel-rust-src-from-kernel-dir.err >&2 || true
fi

if ! nasm -f bin -o "$TMPDIR/trampoline-preflight" src/asm/x86_64/trampoline.asm >/tmp/kernel-nasm.out 2>/tmp/kernel-nasm.err; then
  echo "[build-redox-kernel] nasm preflight failed" >&2
  cat /tmp/kernel-nasm.err >&2 || true
else
  echo "[build-redox-kernel] nasm preflight ok" >&2
fi

cargo rustc \
  --locked \
  --bin kernel \
  --manifest-path Cargo.toml \
  --target targets/x86_64-unknown-kernel.json \
  --release \
  -Z build-std=core,alloc \
  -Z build-std-features=compiler-builtins-mem \
  -- \
  -C link-arg=-T \
  -C link-arg=linkers/x86_64.ld \
  -C link-arg=-z \
  -C link-arg=max-page-size=0x1000 \
  --emit link=kernel.all

/nix/system/profile/bin/llvm-objcopy --strip-debug kernel.all "$out/boot/kernel"
/nix/system/profile/bin/llvm-objcopy --only-keep-debug kernel.all "$out/boot/kernel.sym"
