# ripgrep-source-bundle - Source code + vendored dependencies for building ripgrep on Redox
#
# Creates a directory with the ripgrep source tree and all crate
# dependencies vendored, ready for `cargo build --offline` on the guest.
#
# This enables `snix build .#ripgrep` inside a running Redox VM:
# a real 55-crate Rust project built through a Nix flake on Redox OS.

{ pkgs, ripgrep-src }:

let
  # Vendor all crate dependencies from the lockfile
  vendoredDeps = pkgs.rustPlatform.fetchCargoVendor {
    name = "ripgrep-vendor";
    src = ripgrep-src;
    hash = "sha256-9atn5qyBDy4P6iUoHFhg+TV6Ur71fiah4oTJbBMeEy4=";
  };
in
pkgs.runCommand "ripgrep-source-bundle" { } ''
    mkdir -p $out/.cargo

    # Copy source tree (workspace: root Cargo.toml + crates/ + build.rs)
    # The binary entry point is crates/core/main.rs, not src/main.rs
    cp ${ripgrep-src}/Cargo.toml $out/
    cp ${ripgrep-src}/Cargo.lock $out/
    cp ${ripgrep-src}/build.rs $out/
    cp -r ${ripgrep-src}/crates $out/crates

    # Copy vendored dependencies (includes all platform deps;
    # cargo filters by target at build time)
    cp -r ${vendoredDeps} $out/vendor

    # Builder script and Nix derivation for snix build --file
    cp ${./build-ripgrep.sh} $out/build-ripgrep.sh
    cp ${./build-ripgrep.nix} $out/build.nix

    # Cargo config for offline vendored builds
    cat > $out/.cargo/config.toml << 'EOF'
  [source.crates-io]
  replace-with = "vendored-sources"

  [source.vendored-sources]
  directory = "vendor"

  [build]
  jobs = 2
  target = "x86_64-unknown-redox"

  [target.x86_64-unknown-redox]
  linker = "/nix/system/profile/bin/cc"
  EOF
''
