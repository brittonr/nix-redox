#!/bin/sh
# Builder script for self-compiling snix on Redox OS (Ion syntax).
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out   — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/snix-redox with vendor/ and .cargo/config.toml

let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
export PATH
let LD_LIBRARY_PATH = "/nix/system/profile/lib:/usr/lib/rustc:/lib"
export LD_LIBRARY_PATH
let HOME = "$TMPDIR"
export HOME
let CARGO_HOME = "$TMPDIR/cargo-home"
export CARGO_HOME
let CARGO_INCREMENTAL = "0"
export CARGO_INCREMENTAL
let RUSTC = "/nix/system/profile/bin/rustc"
export RUSTC
let AR = "/nix/system/profile/bin/llvm-ar"
export AR

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to writable directory (source bundle is read-only)
let SRCDIR = "$TMPDIR/snix-src"
cp -r /usr/src/snix-redox "$SRCDIR"

# Ensure .cargo/config.toml survived the copy (cp -r may skip dotfiles)
mkdir -p "$SRCDIR/.cargo"
if not exists -f "$SRCDIR/.cargo/config.toml"
  cp /usr/src/snix-redox/.cargo/config.toml "$SRCDIR/.cargo/config.toml"
end

cd "$SRCDIR"

echo "[build-snix] Starting cargo build (JOBS=2, 168 crates)..."

cargo build --offline
cp target/x86_64-unknown-redox/debug/snix "$out/bin/snix"
echo "[build-snix] snix build complete"
