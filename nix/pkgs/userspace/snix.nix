# snix — Nix evaluator and binary cache client for Redox OS
#
# Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
# Cross-compiles to x86_64-unknown-redox with zero platform-specific code.
#
# snix-eval is vendored locally from https://git.snix.dev/snix/snix.git
# at commit eee477929d6b500936556e2f8a4e187d37525365 (2026-02-05).
# Local vendoring avoids git deps in Cargo.lock which break fetchCargoVendor
# FOD reference checks in Nix 2.31+. The Redox OS platform patch
# (is_second_coordinate) is applied directly in the vendored source.
#
# Binary: snix
# Commands: eval, show-derivation, fetch, path-info, store-verify, repl
#
# Source: in-tree (snix-redox/)

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  unit2nixVendor,
  snix-redox-src,
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      unit2nixVendor
      ;
  };

in
mkUserspace.mkBinary {
  pname = "snix-redox";
  version = "0.4.0";
  src = snix-redox-src;
  binaryName = "snix";
  cargoBuildFlags = "--bin snix --bin stored --bin proxy_namespace_test";

  # Patch upstream fetcher to not panic when no CA certificates exist.
  # Redox has no system cert store; reqwest::Client::new() calls
  # rustls-native-certs which panics with "No CA certificates were loaded".
  # Fix: disable built-in native cert loading so the client creates with
  # an empty root store. Local eval/build work without TLS; remote fetches
  # will fail with a clear TLS handshake error instead of an abort.
  preBuild = ''
    if [ -f upstream/glue/src/fetchers/mod.rs ]; then
      chmod u+w upstream/glue/src/fetchers/mod.rs
      sed -i 's/.user_agent(crate::USER_AGENT)/.user_agent(crate::USER_AGENT)\n                .tls_built_in_native_certs(false)/' \
        upstream/glue/src/fetchers/mod.rs
    fi
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/snix $out/bin/
    if [ -f target/${redoxTarget}/release/stored ]; then
      cp target/${redoxTarget}/release/stored $out/bin/
    fi
    if [ -f target/${redoxTarget}/release/proxy_namespace_test ]; then
      cp target/${redoxTarget}/release/proxy_namespace_test $out/bin/
    fi
    runHook postInstall
  '';

  # Vendor hash — all dependencies are from crates.io (no git sources)
  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Nix evaluator and binary cache client for Redox OS";
    mainProgram = "snix";
  };
}
