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
export CARGO_BUILD_JOBS=2
export CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_PROFILE_DEV_DEBUG=0
export RUSTFLAGS="-Cdebuginfo=0 -Clink-arg=-z -Clink-arg=stack-size=16777216"

mkdir -p "$CARGO_HOME" "$out/bin"

cd /usr/src/workspace-test
cargo build --offline -j2 -p mybin
cp "$TMPDIR/target/x86_64-unknown-redox/debug/mybin" "$out/bin/mybin"
