#!/nix/system/profile/bin/bash
set -e
export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export RUSTC=/nix/system/profile/bin/rustc
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS=2
export CARGO_TARGET_DIR="$TMPDIR/target"

mkdir -p "$CARGO_HOME" "$out/bin"

cd /usr/src/workspace-test
cargo build --offline -j2 -p mybin
cp "$TMPDIR/target/x86_64-unknown-redox/debug/mybin" "$out/bin/mybin"
