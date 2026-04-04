derivation {
  name = "workspace-test";
  builder = "/bin/sh";
  args = ["-c" ''
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
    let CARGO_BUILD_JOBS = "2"
    export CARGO_BUILD_JOBS

    mkdir -p "$CARGO_HOME" "$out/bin"

    cp -r /usr/src/workspace-test "$TMPDIR/src"
    cd "$TMPDIR/src"

    cargo build --offline -j2 -p mybin
    cp target/x86_64-unknown-redox/debug/mybin "$out/bin/mybin"
  ''];
  system = "x86_64-unknown-redox";
}
