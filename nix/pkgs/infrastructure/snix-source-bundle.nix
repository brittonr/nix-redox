# snix-source-bundle - Source code + vendored dependencies for self-compiling snix on Redox
#
# Creates a directory with the full snix-redox source tree, upstream snix
# crates, and all crate dependencies vendored, ready for `cargo build --offline`
# on the guest.

{ pkgs, snix-redox-src, seedPackages }:

let
  stage0Tools = import ./stage0-tools.nix { inherit seedPackages; };
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
    # Includes the scheme ABI revision shared with the refreshed base daemons.
    hash = "sha256-imN+8Jg1BN4VKOTf7CdR0Vpmbtv2gvUSMp/Eh74LaEg=";
  };
in
pkgs.runCommand "snix-source-bundle" { } ''
  mkdir -p $out/.cargo

  # Copy source tree with upstream crates
  cp ${combinedSrc}/Cargo.toml $out/
  cp ${combinedSrc}/Cargo.lock $out/
  # All proc-macro crates now build from the real vendored sources. The
  # serde/prost/thiserror derives and the remaining derive crates are covered
  # by the guest build proof; clap_derive, pin-project-internal, tokio-macros
  # and serde_with_macros were unused patch candidates. Keep only the
  # non-proc-macro dependency patches that the resolution still selects.
  ${pkgs.perl}/bin/perl -0pi -e 's#(tracing-attributes = \{ path = "vendor-patches/tracing-attributes-0\.1\.31" \}\n)#$1reqwest-middleware = { path = "vendor-patches/reqwest-middleware-0.5.1" }\nreqwest-tracing = { path = "vendor-patches/reqwest-tracing-0.6.0" }\nautocfg = { path = "vendor-patches/autocfg-1.5.0" }\nserde_qs = { path = "vendor-patches/serde_qs-0.12.0" }\ntonic-health = { path = "vendor-patches/tonic-health-0.13.1" }\ntower = { path = "vendor-patches/tower-0.4.13" }\n#' $out/Cargo.toml
  cp -r ${combinedSrc}/src $out/src
  cp -r ${combinedSrc}/upstream $out/upstream
  if [ -d ${combinedSrc}/vendor-patches ]; then
    cp -r ${combinedSrc}/vendor-patches $out/vendor-patches
  fi

  # Copy vendored dependencies
  cp -r ${vendoredDeps} $out/vendor

  # Builder script and Nix derivation for snix build --file
  cp ${./build-snix.sh} $out/build-snix.sh
  cp ${./build-snix.nix} $out/build.nix
  printf '%s\n' ${pkgs.lib.escapeShellArg ("{\n" + pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (name: value: "  ${name} = builtins.storePath \"${value}\";\n") stage0Tools) + "}")} > $out/stage0-tools.nix

  # Reuse fetchCargoVendor's exact registry/git ordering and revision pins.
  # A new git dependency can renumber source-git-N directories.
  substitute ${vendoredDeps}/.cargo/config.toml $out/.cargo/config.toml \
    --replace-fail '@vendor@' 'vendor'
  cat >> $out/.cargo/config.toml <<'EOF'

[build]
target = "x86_64-unknown-redox"

[target.x86_64-unknown-redox]
linker = "${stage0Tools.sysroot}/bin/cc"
EOF
''

