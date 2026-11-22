#!/bin/bash
set -e
if [ -z "${NIX_TOOL_PATH:-}" ]; then
  . "${0%/*}/tool-env.sh"
fi
export PATH="${NIX_TOOL_PATH:?}"
export LD_LIBRARY_PATH="${NIX_LD_LIBRARY_PATH:?}"
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export RUSTC="${NIX_RUSTC:?}"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_TERM_PROGRESS_WHEN=never
export CARGO_PROFILE_DEV_DEBUG=0
export RUSTFLAGS="-Cdebuginfo=0 -Clink-arg=-z -Clink-arg=stack-size=16777216"
export AR="${NIX_AR:?}"

mkdir -p "$CARGO_HOME" "$out/bin"

cd /usr/src/cc-dep-test
if ! cargo build --offline -j2 >"$TMPDIR/cargo.stdout" 2>"$TMPDIR/cargo.stderr"; then
  cat "$TMPDIR/cargo.stdout" >&2 || true
  cat "$TMPDIR/cargo.stderr" >&2 || true
  exit 1
fi
cp "$TMPDIR/target/x86_64-unknown-redox/debug/cc-dep-test" "$out/bin/cc-dep-test"
