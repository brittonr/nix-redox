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

mkdir -p "$HOME" "$CARGO_HOME" "$CARGO_TARGET_DIR" "$out/boot/EFI/BOOT"

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

wrapper="$TMPDIR/rustc-sysroot"
cp /nix/system/profile/bin/bash "$wrapper"
printf '%s\n' '#!/nix/system/profile/bin/bash' "exec /nix/system/profile/bin/rustc --sysroot $custom_sysroot \"\$@\"" > "$wrapper"
export RUSTC="$wrapper"

cd /usr/src/native-kernel-rebuild/bootloader

cargo rustc \
  --locked \
  --bin bootloader \
  --target x86_64-unknown-uefi \
  --release \
  -Z build-std=core,alloc \
  -Z build-std-features=compiler-builtins-mem

cp target/x86_64-unknown-uefi/release/bootloader.efi "$out/boot/EFI/BOOT/BOOTX64.EFI"
