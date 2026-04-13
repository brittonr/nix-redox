#!/nix/system/profile/bin/bash
# Builder script for compiling ripgrep on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out   — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/ripgrep with vendor/ and .cargo/config.toml

set -e
export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export RUSTC=/nix/system/profile/bin/rustc
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$TMPDIR/target"
export AR=/nix/system/profile/bin/llvm-ar

mkdir -p "$CARGO_HOME" "$out/bin"

SRCDIR="/usr/src/ripgrep"
cd "$SRCDIR"

echo "[build-ripgrep] Starting cargo build (JOBS=2, 33 crates)..."

cargo build --offline --bin rg -j2
cp "$TMPDIR/target/x86_64-unknown-redox/debug/rg" "$out/bin/rg"
echo "[build-ripgrep] ripgrep build complete"
