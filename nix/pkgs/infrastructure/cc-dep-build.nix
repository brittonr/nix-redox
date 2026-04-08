derivation {
  name = "cc-dep-test";
  builder = "/nix/system/profile/bin/bash";
  args = ["-c" ''
set -e
export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export CARGO_INCREMENTAL=0
export AR=/nix/system/profile/bin/llvm-ar

mkdir -p "$CARGO_HOME" "$out/bin"

cp -r /usr/src/cc-dep-test "$TMPDIR/src"
cd "$TMPDIR/src"

cargo build --offline -j2
cp target/x86_64-unknown-redox/debug/cc-dep-test "$out/bin/cc-dep-test"
  ''];
  system = "x86_64-unknown-redox";
}
