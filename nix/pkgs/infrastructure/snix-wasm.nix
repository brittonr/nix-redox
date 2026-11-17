# Direct evaluator only: no Redox CLI, store services, build executor, or guest patches.
{ pkgs, lib ? pkgs.lib
, rustToolchain ? pkgs.rust-bin.stable.latest.minimal.override { targets = [ "wasm32-unknown-unknown" ]; }
, wasmBindgenCli ? pkgs.wasm-bindgen-cli_0_2_100
}:
let
  revision = "34604636d7e3adbad6f7f909c98bb493f26855f9";
  # Same mirror and fixed hash as snix-upstream-source.nix.
  upstream = pkgs.fetchgit {
    url = "https://github.com/anthropics/snix.git";
    rev = revision;
    hash = "sha256-of/rQYKmysPEqO2Snx199VcZjey+5YxJZD3QgLQanN4=";
  };
  source = pkgs.runCommand "snix-wasm-source-${builtins.substring 0 10 revision}" { } ''
    mkdir -p $out/upstream
    cp ${../../../snix-wasm/Cargo.toml} $out/Cargo.toml
    cp ${../../../snix-wasm/Cargo.lock} $out/Cargo.lock
    cp -r ${../../../snix-wasm/src} $out/src
    cp -r ${../../../snix-wasm/fixtures} $out/fixtures
    cp -r ${upstream}/snix/eval $out/upstream/eval
    cp ${upstream}/snix/LICENSE $out/COPYING
  '';
  rustPlatform = pkgs.makeRustPlatform { cargo = rustToolchain; rustc = rustToolchain; };
in
assert lib.assertMsg (wasmBindgenCli.version == "0.2.100") "snix-wasm requires wasm-bindgen CLI 0.2.100, matching Cargo.lock";
rustPlatform.buildRustPackage {
  pname = "snix-wasm";
  version = "0.1.0";
  src = source;
  cargoLock.lockFile = ../../../snix-wasm/Cargo.lock;
  nativeBuildInputs = [ wasmBindgenCli ];
  # The worker is disposable; cap its linear memory as well as its wall time.
  RUSTFLAGS = "-C link-arg=--max-memory=268435456";
  buildPhase = ''
    runHook preBuild
    cargo build --offline --locked --release --target wasm32-unknown-unknown -p snix-wasm
    runHook postBuild
  '';
  doCheck = false; # Browser/guest comparison runs against the integrated live site.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/playground/wasm
    cp ${../../../site/playground}/*.js ${../../../site/playground}/*.css $out/share/playground/
    wasm-bindgen --target web --no-typescript --out-name snix_wasm \
      --out-dir $out/share/playground/wasm target/wasm32-unknown-unknown/release/snix_wasm.wasm
    cp -r fixtures $out/share/playground/fixtures
    cp COPYING $out/share/playground/wasm/COPYING
    cp ${../../../LICENSE} $out/share/playground/LICENSE
    # Supply corresponding evaluator and adapter source with the distributed module.
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -czf $out/share/playground/wasm/snix-wasm-source.tar.gz -C ${source} .
    printf '%s\n' '${builtins.toJSON { evaluatorRevision = revision; fixtureVersion = 1; protocol = 1; wasmBindgen = "0.2.100"; memoryLimitBytes = 268435456; }}' \
      > $out/share/playground/wasm/build-metadata.json
    runHook postInstall
  '';
  passthru = { inherit source; evaluatorRevision = revision; fixtures = ../../../snix-wasm/fixtures/v1; };
  meta = {
    description = "Pinned Snix expression evaluator and independent browser-worker playground";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.unix;
  };
}
