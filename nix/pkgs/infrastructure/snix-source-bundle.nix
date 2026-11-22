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

  # The upstream build.rs files can consume pregenerated descriptor sets, but
  # tonic_build::skip_protoc_run() still does not materialize the Rust modules
  # that tonic::include_proto! expects on the Redox guest. Ship host-generated
  # modules in the source bundle and copy them into OUT_DIR from build.rs.
  chmod -R u+w $out/upstream/castore/protos $out/upstream/store/protos $out/upstream/build/protos
  chmod u+w $out/upstream/castore/build.rs $out/upstream/store/build.rs $out/upstream/build/build.rs
  cp $out/vendor-patches/generated-protos/snix.castore.v1.rs $out/upstream/castore/protos/snix.castore.v1.rs
  cp $out/vendor-patches/generated-protos/snix.store.v1.rs $out/upstream/store/protos/snix.store.v1.rs
  cp $out/vendor-patches/generated-protos/snix.build.v1.rs $out/upstream/build/protos/snix.build.v1.rs
  SNIX_BUNDLE_OUT="$out" ${pkgs.python3}/bin/python3 - <<'PY'
import os
from pathlib import Path
bundle_out = Path(os.environ["SNIX_BUNDLE_OUT"])
for crate in ("castore", "store", "build"):
    build_rs = bundle_out / "upstream" / crate / "build.rs"
    text = build_rs.read_text()
    descriptor = f"snix.{crate}.v1.bin"
    generated = f"snix.{crate}.v1.rs"
    marker = "fn pregenerated_rust_path() -> PathBuf"
    if marker not in text:
        insert = f"""

fn pregenerated_rust_path() -> PathBuf {{
    PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("protos")
        .join("{generated}")
}}
"""
        anchor = "\n\n  fn compile_from_pregenerated() -> Result<bool> {"
        if anchor not in text:
            raise SystemExit(f"expected compile_from_pregenerated anchor not found in {build_rs}")
        text = text.replace(anchor, insert + anchor, 1)
    old = """      let empty: &[&str] = &[];
      configured_builder()
          .file_descriptor_set_path(&descriptor_path)
          .skip_protoc_run()
          .compile_protos(empty, empty)?;
"""
    new = f"""      let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
      let rust_path = pregenerated_rust_path();
      if rust_path.is_file() {{
          fs::copy(&rust_path, out_dir.join("{generated}"))?;
      }} else {{
          let empty: &[&str] = &[];
          configured_builder()
              .file_descriptor_set_path(&descriptor_path)
              .skip_protoc_run()
              .compile_protos(empty, empty)?;
      }}
"""
    if old not in text:
        raise SystemExit(f"expected pregenerated compile block not found in {build_rs}")
    build_rs.write_text(text.replace(old, new, 1))
PY

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
jobs = 1
target = "x86_64-unknown-redox"

[target.x86_64-unknown-redox]
linker = "${stage0Tools.sysroot}/bin/cc"

[env]
# Avoid the curve25519-dalek SIMD backend in the Redox guest self-compile.
# The SIMD backend requires curve25519-dalek-derive to generate specialized
# AVX modules, and Redox guest rustc currently stalls or fails in proc-macro
# expansion paths. The serial backend is sufficient for building snix.
CARGO_CFG_CURVE25519_DALEK_BACKEND = "serial"
EOF
''

