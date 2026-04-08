#!/nix/system/profile/bin/bash
# Builder script for self-compiling snix on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out    — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/snix-redox with vendor/ and .cargo/config.toml

set -e

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS=2
export RUSTFLAGS="-C panic=abort"
export RUSTC=/nix/system/profile/bin/rustc
export AR=/nix/system/profile/bin/llvm-ar

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to a writable directory (source bundle is read-only)
SRCDIR="$TMPDIR/snix-src"
mkdir -p "$SRCDIR"
cp -r /usr/src/snix-redox/. "$SRCDIR"

# Ensure .cargo/config.toml survived the copy (defensive; dotfiles should copy)
mkdir -p "$SRCDIR/.cargo"
if [ ! -f "$SRCDIR/.cargo/config.toml" ]; then
  cp /usr/src/snix-redox/.cargo/config.toml "$SRCDIR/.cargo/config.toml"
fi

cd "$SRCDIR"

echo "[build-snix] Starting cargo build (JOBS=2, 168 crates)..."
cargo build --offline -j2
cp target/x86_64-unknown-redox/debug/snix "$out/bin/snix"
echo "[build-snix] snix build complete"
