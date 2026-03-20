# snix-source-bundle - Source code + vendored dependencies for self-compiling snix on Redox
#
# Creates a directory with the full snix-redox source tree, upstream snix
# crates, and all crate dependencies vendored, ready for `cargo build --offline`
# on the guest.

{ pkgs, snix-redox-src }:

let
  snixUpstreamSource = import ./snix-upstream-source.nix { inherit pkgs; };

  # Compose source with upstream crates (same as the cross-build does)
  combinedSrc = pkgs.runCommand "snix-redox-combined-src" { } ''
    cp -r ${snix-redox-src} $out
    chmod -R u+w $out
    rm -f $out/upstream
    cp -r ${snixUpstreamSource} $out/upstream
  '';

  # Vendor all crate dependencies from the lockfile
  vendoredDeps = pkgs.rustPlatform.fetchCargoVendor {
    name = "snix-redox-vendor";
    src = combinedSrc;
    # Dummy hash — replace after first build attempt reveals the real hash.
    # Run: nix build .#snix-source-bundle 2>&1 | grep "got:"
    hash = "sha256-+447IcBJotajic0ClysP1cVxY7RYWYB19KKlZUqnoT0=";
  };
in
pkgs.runCommand "snix-source-bundle" { } ''
  mkdir -p $out/.cargo

  # Copy source tree with upstream crates
  cp ${combinedSrc}/Cargo.toml $out/
  cp ${combinedSrc}/Cargo.lock $out/
  cp -r ${combinedSrc}/src $out/src
  cp -r ${combinedSrc}/upstream $out/upstream

  # Copy vendored dependencies
  cp -r ${vendoredDeps} $out/vendor

  # Builder script and Nix derivation for snix build --file
  cp ${./build-snix.sh} $out/build-snix.sh
  cp ${./build-snix.nix} $out/build.nix

  # Cargo config for offline vendored builds
  cat > $out/.cargo/config.toml <<'EOF'
  [source.crates-io]
  replace-with = "vendored-sources"

  [source."git+https://github.com/tvlfyi/wu-manber.git"]
  git = "https://github.com/tvlfyi/wu-manber.git"
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
