# cc-dep-test-bundle — Rust crate with C dependency via cc-rs for on-guest build test
#
# Contains a Rust binary that calls a C function via FFI. The build.rs uses
# cc-rs to compile the C source. Tests that the CC wrapper → clang → lld
# pipeline works inside snix's per-path sandbox.

{ pkgs }:

let
  # Vendor the cc crate for offline builds
  ccCrateSrc = pkgs.fetchurl {
    url = "https://crates.io/api/v1/crates/cc/1.2.21/download";
    hash = "sha256-hpF4KUVFHBw4OULEh02+Y4FPYctX73c82ilyaCt7s8A=";
  };
in
pkgs.runCommand "cc-dep-test-bundle" { } ''
  mkdir -p $out/src $out/.cargo $out/vendor/cc

  # ── C source ────────────────────────────────────────────────────
  cat > $out/src/hello.c << 'CSRC'
  int greet_from_c(void) {
      return 42;
  }
  CSRC

  # ── Rust source with FFI ────────────────────────────────────────
  cat > $out/src/main.rs << 'RUST'
  extern "C" {
      fn greet_from_c() -> i32;
  }

  fn main() {
      let result = unsafe { greet_from_c() };
      println!("C function returned: {}", result);
      if result == 42 {
          println!("CC_DEP_OK");
      } else {
          println!("CC_DEP_FAIL: expected 42, got {}", result);
      }
  }
  RUST

  # ── build.rs (uses cc-rs) ──────────────────────────────────────
  cat > $out/build.rs << 'BUILD'
  fn main() {
      cc::Build::new()
          .file("src/hello.c")
          .compile("hello");
  }
  BUILD

  # ── Cargo.toml ─────────────────────────────────────────────────
  cat > $out/Cargo.toml << 'TOML'
  [package]
  name = "cc-dep-test"
  version = "0.1.0"
  edition = "2021"

  [build-dependencies]
  cc = "1.2.21"
  TOML

  # ── Vendor the cc crate ────────────────────────────────────────
  mkdir -p $out/vendor/cc/src
  tar xzf ${ccCrateSrc} -C $out/vendor/cc --strip-components=1
  echo '{"files":{}}' > $out/vendor/cc/.cargo-checksum.json

  # ── Cargo.lock ─────────────────────────────────────────────────
  cat > $out/Cargo.lock << 'LOCK'
  version = 3

  [[package]]
  name = "cc"
  version = "1.2.21"
  source = "registry+https://github.com/rust-lang/crates.io-index"

  [[package]]
  name = "cc-dep-test"
  version = "0.1.0"
  dependencies = [
   "cc",
  ]
  LOCK

  # ── .cargo/config.toml ─────────────────────────────────────────
  cat > $out/.cargo/config.toml << 'CFG'
  [source.crates-io]
  replace-with = "vendored-sources"

  [source.vendored-sources]
  directory = "vendor"

  [build]
  jobs = 2
  target = "x86_64-unknown-redox"

  [target.x86_64-unknown-redox]
  linker = "/nix/system/profile/bin/cc"
  CFG

  # ── build.nix (for snix build --file) ──────────────────────────
  cp ${./cc-dep-build.nix} $out/build.nix
''
