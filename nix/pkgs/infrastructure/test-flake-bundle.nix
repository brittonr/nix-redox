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

  # ── Builder script ─────────────────────────────────────────────
  cat > $out/build-hello.sh << 'BUILDER'
set -e
export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to writable location
cp -r "$src" "$TMPDIR/src"
chmod -R u+w "$TMPDIR/src"

# Create cargo config for offline build
mkdir -p "$TMPDIR/src/.cargo"
cat > "$TMPDIR/src/.cargo/config.toml" << CFG
[build]
jobs = 2
target = "x86_64-unknown-redox"
[target.x86_64-unknown-redox]
linker = "/nix/system/profile/bin/cc"
CFG

cd "$TMPDIR/src"
cargo build --offline -j2 2>&1
cp target/x86_64-unknown-redox/debug/hello-flake "$out/bin/hello"
BUILDER

  # ── flake.nix ──────────────────────────────────────────────────
  cat > $out/flake.nix << 'FLAKE'
{
  description = "Test flake for snix build validation";

  outputs = { self, ... }: {
    packages."x86_64-unknown-redox".hello = derivation {
      name = "hello-flake";
      builder = "/nix/system/profile/bin/bash";
      args = [ "''${builtins.toString self}/build-hello.sh" ];
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
