derivation {
  name = "workspace-test";
  builder = "/nix/system/profile/bin/bash";
  args = ["-c" ''
    set -e
    export PATH=/nix/system/profile/bin:/bin:/usr/bin
    export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
    export HOME="$TMPDIR"
    export CARGO_HOME="$TMPDIR/cargo-home"
    export CARGO_INCREMENTAL=0
    export CARGO_BUILD_JOBS=2

    mkdir -p "$CARGO_HOME" "$out/bin"

    cp -r /usr/src/workspace-test "$TMPDIR/src"
    chmod -R u+w "$TMPDIR/src"
    cd "$TMPDIR/src"

    cargo build --offline -j2 -p mybin 2>&1
    cp target/x86_64-unknown-redox/debug/mybin "$out/bin/mybin"
  ''];
  system = "x86_64-unknown-redox";
}
