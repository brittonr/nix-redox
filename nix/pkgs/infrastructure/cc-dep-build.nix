derivation {
  name = "cc-dep-test";
  builder = "/nix/system/profile/bin/bash";
  args = ["-c" ''
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

cd /usr/src/cc-dep-test
cargo build --offline -j2
cp "$TMPDIR/target/x86_64-unknown-redox/debug/cc-dep-test" "$out/bin/cc-dep-test"
  ''];
  system = "x86_64-unknown-redox";
}
