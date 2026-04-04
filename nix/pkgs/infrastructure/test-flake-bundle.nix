# test-flake-bundle — Minimal flake for testing `snix build .#hello` on Redox
#
# Contains:
#   - flake.nix: outputs a hello-world Rust package
#   - flake.lock: uses a path-type input (no HTTP needed)
#   - src/: Rust source for a hello binary
#   - build-hello.sh: builder script invoked by the derivation
#
# The flake uses a `path`-type input pointing to "./src" so the entire
# test works offline without network access.

{ pkgs }:

pkgs.runCommand "test-flake-bundle" { } ''
  mkdir -p $out/src

  # ── Rust source ─────────────────────────────────────────────────
  mkdir -p $out/src/src
  cat > $out/src/Cargo.toml << 'TOML'
[package]
name = "hello-flake"
version = "0.1.0"
edition = "2021"
TOML

  cat > $out/src/src/main.rs << 'RUST'
fn main() {
    println!("Hello from flake!");
}
RUST

  # ── Builder script (Ion syntax — static binary, works in sandbox) ──
  cat > $out/build-hello.ion << 'BUILDER'
let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
export PATH
let LD_LIBRARY_PATH = "/nix/system/profile/lib:/usr/lib/rustc:/lib"
export LD_LIBRARY_PATH
let HOME = "$TMPDIR"
export HOME
let CARGO_HOME = "$TMPDIR/cargo-home"
export CARGO_HOME
mkdir -p "$CARGO_HOME" "$out/bin"
cp -r "$src" "$TMPDIR/src"
mkdir -p "$TMPDIR/src/.cargo"
echo "[build]" > "$TMPDIR/src/.cargo/config.toml"
echo "jobs = 2" >> "$TMPDIR/src/.cargo/config.toml"
echo 'target = "x86_64-unknown-redox"' >> "$TMPDIR/src/.cargo/config.toml"
echo "[target.x86_64-unknown-redox]" >> "$TMPDIR/src/.cargo/config.toml"
echo 'linker = "/nix/system/profile/bin/cc"' >> "$TMPDIR/src/.cargo/config.toml"
cd "$TMPDIR/src"
cargo build --offline -j2
cp target/x86_64-unknown-redox/debug/hello-flake "$out/bin/hello"
BUILDER

  # ── flake.nix ──────────────────────────────────────────────────
  cat > $out/flake.nix << 'FLAKE'
{
  description = "Test flake for snix build validation";

  outputs = { self, ... }: {
    packages."x86_64-unknown-redox".hello = derivation {
      name = "hello-flake";
      builder = "/bin/sh";
      args = [ "''${builtins.toString self}/build-hello.ion" ];
      system = "x86_64-unknown-redox";
      src = "''${builtins.toString self}/src";
    };
  };
}
FLAKE

  # ── flake.lock ─────────────────────────────────────────────────
  # Minimal lock with no inputs (self-contained flake)
  cat > $out/flake.lock << 'LOCK'
{
  "version": 7,
  "root": "root",
  "nodes": {
    "root": {}
  }
}
LOCK
''
