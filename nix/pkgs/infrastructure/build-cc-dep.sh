#!/nix/system/profile/bin/bash
set -e
export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export RUSTC=/nix/system/profile/bin/rustc
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$TMPDIR/target"
export CARGO_TERM_PROGRESS_WHEN=never
export AR=/nix/system/profile/bin/llvm-ar

mkdir -p "$CARGO_HOME" "$out/bin"

cd /usr/src/cc-dep-test
if ! cargo build --offline -j2 >"$TMPDIR/cargo.stdout" 2>"$TMPDIR/cargo.stderr"; then
  cat "$TMPDIR/cargo.stdout" >&2 || true
  cat "$TMPDIR/cargo.stderr" >&2 || true
  exit 1
fi
cp "$TMPDIR/target/x86_64-unknown-redox/debug/cc-dep-test" "$out/bin/cc-dep-test"
