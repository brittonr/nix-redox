# workspace-test-bundle — Cargo workspace with lib + bin for on-guest build test
#
# Two-crate workspace: mylib (library) and mybin (binary depending on mylib).
# Tests that cargo workspace builds with inter-crate path dependencies work
# inside snix's per-path sandbox.

{ pkgs }:

pkgs.runCommand "workspace-test-bundle" { } ''
  mkdir -p $out/mylib/src $out/mybin/src $out/.cargo

  # Workspace Cargo.toml
  cat > $out/Cargo.toml << 'TOML'
[workspace]
resolver = "2"
members = ["mylib", "mybin"]
TOML

  # mylib
  cat > $out/mylib/Cargo.toml << 'TOML'
[package]
name = "mylib"
version = "0.1.0"
edition = "2021"
TOML

  cat > $out/mylib/src/lib.rs << 'RUST'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

pub fn greeting() -> &'static str {
    "Hello from mylib!"
}
RUST

  # mybin
  cat > $out/mybin/Cargo.toml << 'TOML'
[package]
name = "mybin"
version = "0.1.0"
edition = "2021"

[dependencies]
mylib = { path = "../mylib" }
TOML

  cat > $out/mybin/src/main.rs << 'RUST'
fn main() {
    let sum = mylib::add(19, 23);
    let msg = mylib::greeting();
    println!("{}", msg);
    println!("19 + 23 = {}", sum);
    if sum == 42 && msg == "Hello from mylib!" {
        println!("WORKSPACE_OK");
    } else {
        println!("WORKSPACE_FAIL: sum={} msg={}", sum, msg);
    }
}
RUST

  # Cargo.lock
  cat > $out/Cargo.lock << 'LOCK'
version = 3

[[package]]
name = "mybin"
version = "0.1.0"
dependencies = [
 "mylib",
]

[[package]]
name = "mylib"
version = "0.1.0"
LOCK

  # .cargo/config.toml
  cat > $out/.cargo/config.toml << 'CFG'
[build]
jobs = 2
target = "x86_64-unknown-redox"

[target.x86_64-unknown-redox]
linker = "/nix/system/profile/bin/cc"
CFG

  # build.nix (external file to avoid Nix string escaping issues)
  cp ${./workspace-build.nix} $out/build.nix
''
