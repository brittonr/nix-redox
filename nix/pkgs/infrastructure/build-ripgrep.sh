#!/bin/bash
# Builder script for compiling ripgrep on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out   — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/ripgrep with vendor/ and .cargo/config.toml

set -e
export PATH="${NIX_TOOL_PATH:?}"
export LD_LIBRARY_PATH="${NIX_LD_LIBRARY_PATH:?}"
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export RUSTC="${NIX_RUSTC:?}"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_TERM_PROGRESS_WHEN=never
export AR="${NIX_AR:?}"

mkdir -p "$CARGO_HOME" "$out/bin"

SRCDIR="/usr/src/ripgrep"
cd "$SRCDIR"

if ! cargo build --offline --bin rg -j2 >"$TMPDIR/cargo.stdout" 2>"$TMPDIR/cargo.stderr"; then
  cat "$TMPDIR/cargo.stdout" >&2 || true
  cat "$TMPDIR/cargo.stderr" >&2 || true
  exit 1
fi
cp "$TMPDIR/target/x86_64-unknown-redox/debug/rg" "$out/bin/rg"
