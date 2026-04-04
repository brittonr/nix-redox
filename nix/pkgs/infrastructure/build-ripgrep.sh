#!/bin/sh
# Builder script for compiling ripgrep on Redox OS (Ion syntax).
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out   — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/ripgrep with vendor/ and .cargo/config.toml

let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
export PATH
let LD_LIBRARY_PATH = "/nix/system/profile/lib:/usr/lib/rustc:/lib"
export LD_LIBRARY_PATH
let HOME = "$TMPDIR"
export HOME
let CARGO_HOME = "$TMPDIR/cargo-home"
export CARGO_HOME
let AR = "/nix/system/profile/bin/llvm-ar"
export AR

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to writable directory (source bundle is read-only)
let SRCDIR = "$TMPDIR/rg-src"
cp -r /usr/src/ripgrep "$SRCDIR"

# Ensure .cargo/config.toml survived the copy
mkdir -p "$SRCDIR/.cargo"
if not exists -f "$SRCDIR/.cargo/config.toml"
  cp /usr/src/ripgrep/.cargo/config.toml "$SRCDIR/.cargo/config.toml"
end

cd "$SRCDIR"

echo "[build-ripgrep] Starting cargo build (JOBS=2, 33 crates)..."

cargo build --offline --bin rg -j2
cp target/x86_64-unknown-redox/debug/rg "$out/bin/rg"
echo "[build-ripgrep] ripgrep build complete"
