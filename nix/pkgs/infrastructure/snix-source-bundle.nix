# snix-source-bundle - Source code + vendored dependencies for self-compiling snix on Redox
#
# Creates a directory with the full snix-redox source tree and all crate
# dependencies vendored, ready for `cargo build --offline` on the guest.

{ pkgs, snix-redox-src }:

let
  # Vendor all crate dependencies from the lockfile
  vendoredDeps = pkgs.rustPlatform.fetchCargoVendor {
    name = "snix-redox-vendor";
    src = snix-redox-src;
    hash = "sha256-/XLkVwe6hHD/IaLhYVdAlxryHrVt/dJabWD1whcFk4g=";
  };
in
pkgs.runCommand "snix-source-bundle" { } ''
  mkdir -p $out/.cargo

  # Copy source tree
  cp ${snix-redox-src}/Cargo.toml $out/
  cp ${snix-redox-src}/Cargo.lock $out/
  cp -r ${snix-redox-src}/src $out/src
  cp -r ${snix-redox-src}/snix-eval-vendored $out/snix-eval-vendored
  cp -r ${snix-redox-src}/nix-compat-redox $out/nix-compat-redox
  cp -r ${snix-redox-src}/nix-compat-derive $out/nix-compat-derive

  # Copy vendored dependencies
  cp -r ${vendoredDeps} $out/vendor

  # Cargo config for offline vendored builds
  cat > $out/.cargo/config.toml <<'EOF'
  [source.crates-io]
  replace-with = "vendored-sources"

  [source.vendored-sources]
  directory = "vendor"
  EOF
''
