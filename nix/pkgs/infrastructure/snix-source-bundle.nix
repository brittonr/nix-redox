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
    hash = "sha256-FY3tf0r8XIFqCtlUHHHEtg9kObU0YWXeDYlIT4WP1Jg=";
  };
in
pkgs.runCommand "snix-source-bundle" { } ''
  mkdir -p $out/.cargo

  # Copy source tree with upstream crates
  cp ${combinedSrc}/Cargo.toml $out/
  cp ${combinedSrc}/Cargo.lock $out/
  # The self-hosted Redox rustc currently spins compiling some upstream
  # proc-macro crates. Keep host/cross validation on the real derives where the
  # generated semantics are tested, but make the guest source bundle use tiny
  # local shims so the focused snix self-compile can progress past proc-macro
  # compilation. The self-hosting test only needs this derivation to build the
  # snix binary; host tests continue to validate the real serde/prost paths.
  ${pkgs.perl}/bin/perl -0pi -e 's#(tracing-attributes = \{ path = "vendor-patches/tracing-attributes-0\.1\.31" \}\n)#$1serde_derive = { path = "vendor-patches/serde_derive-1.0.228" }\nprost-derive = { path = "vendor-patches/prost-derive-0.13.5" }\ntokio-macros = { path = "vendor-patches/tokio-macros-2.6.1" }\nthiserror-impl = { path = "vendor-patches/thiserror-impl-2.0.18" }\nthiserror-impl-1 = { package = "thiserror-impl", path = "vendor-patches/thiserror-impl-1.0.69" }\nasync-trait = { path = "vendor-patches/async-trait-0.1.89" }\npin-project-internal = { path = "vendor-patches/pin-project-internal-1.1.11" }\nclap_derive = { path = "vendor-patches/clap_derive-4.6.0" }\nreqwest-middleware = { path = "vendor-patches/reqwest-middleware-0.5.1" }\nrustversion = { path = "vendor-patches/rustversion-1.0.22" }\nreqwest-tracing = { path = "vendor-patches/reqwest-tracing-0.6.0" }\nserde_with_macros = { path = "vendor-patches/serde_with_macros-3.18.0" }\nautocfg = { path = "vendor-patches/autocfg-1.5.0" }\ncurve25519-dalek-derive = { path = "vendor-patches/curve25519-dalek-derive-0.1.1" }\nproc-macro-error-attr2 = { path = "vendor-patches/proc-macro-error-attr2-2.0.0" }\nnum_enum_derive = { path = "vendor-patches/num_enum_derive-0.7.6" }\nserde_qs = { path = "vendor-patches/serde_qs-0.12.0" }\nstructmeta-derive = { path = "vendor-patches/structmeta-derive-0.1.6" }\ntonic-health = { path = "vendor-patches/tonic-health-0.13.1" }\ntower = { path = "vendor-patches/tower-0.4.13" }\nauto_impl = { path = "vendor-patches/auto_impl-1.3.0" }\n#' $out/Cargo.toml
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

  # Cargo config for offline vendored builds.
  # fetchCargoVendor lays crates out under vendor/source-registry-0/
  # and git deps under vendor/source-git-0/.
  cat > $out/.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-source-registry-0"

[source.vendored-source-registry-0]
directory = "vendor/source-registry-0"

[source."git+https://github.com/tvlfyi/wu-manber.git"]
git = "https://github.com/tvlfyi/wu-manber.git"
replace-with = "vendored-source-git-0"

[source.vendored-source-git-0]
directory = "vendor/source-git-0"

[build]
jobs = 1
target = "x86_64-unknown-redox"

[target.x86_64-unknown-redox]
linker = "/nix/system/profile/bin/cc"

[env]
# Avoid the curve25519-dalek SIMD backend in the Redox guest self-compile.
# The SIMD backend requires curve25519-dalek-derive to generate specialized
# AVX modules, and Redox guest rustc currently stalls or fails in proc-macro
# expansion paths. The serial backend is sufficient for building snix.
CARGO_CFG_CURVE25519_DALEK_BACKEND = "serial"
EOF
''

