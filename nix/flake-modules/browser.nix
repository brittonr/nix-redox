# Browser artifacts use the same Redox system builder and one machine contract.
{
  pkgs,
  lib,
  self,
  self',
  ...
}:
let
  env = self'.legacyPackages.redoxEnv;
  inherit (env)
    rustToolchain
    redoxTarget
    modularPkgs
    redoxLib
    ;
  engines = import ../browser/engine.nix { inherit pkgs; };
  flush = import ../browser/flush.nix {
    inherit pkgs rustToolchain redoxTarget;
    inherit (modularPkgs.system) relibc;
    inherit (redoxLib) stubLibs;
  };
  cacheTests = import ../tests/binary-cache.nix { inherit pkgs lib; };
  mkRuntimeFixture =
    namePrefix:
    import ../tests/cache-runtime-fixture.nix {
      inherit
        pkgs
        lib
        rustToolchain
        redoxTarget
        namePrefix
        ;
      inherit (modularPkgs.system) relibc;
      inherit (redoxLib) stubLibs;
    };
  runtimeFixture = mkRuntimeFixture "cache-runtime";
  downloadableRuntimeFixture = mkRuntimeFixture "browser-download-runtime";
  browserSystem = self'.legacyPackages.mkRedoxSystem {
    modules = [ ../redox-system/profiles/browser-demo.nix ];
  };
  graphicalSystem = self'.legacyPackages.mkRedoxSystem {
    modules = [ ../redox-system/profiles/browser-graphical.nix ];
  };
  image = import ../browser/image.nix {
    inherit pkgs;
    system = browserSystem;
    machine = engines.machine;
  };
  graphicalImage = import ../browser/image.nix {
    inherit pkgs;
    system = graphicalSystem;
    machine = ../browser/graphical-machine.json;
  };
  evaluator = import ../pkgs/infrastructure/snix-wasm.nix {
    inherit pkgs;
    rustToolchain = rustToolchain.override { targets = [ "wasm32-unknown-unknown" ]; };
  };
  downloadableCache =
    (import ../lib/mk-binary-cache.nix {
      hostPkgs = pkgs;
      inherit lib;
    })
      {
        packages.fd = self'.packages.fd;
        packages.download-closure-fixture = downloadableRuntimeFixture.package;
        target = redoxTarget;
      };
  revision =
    self.rev
      or "dirty-${builtins.substring 0 20 (builtins.hashString "sha256" (toString self.outPath))}";
  mkBrowserSite =
    {
      engine ? engines.engine,
      vendor ? engines.vendor,
      guestImage ? image,
      machine ? engines.machine,
      firmware ? engines.firmware,
      snapshot ? null,
      guestEvaluator ? evaluator,
      cache ? downloadableCache,
    }:
    import ../browser/site.nix {
      inherit
        pkgs
        lib
        engine
        vendor
        machine
        firmware
        revision
        snapshot
        cache
        ;
      image = guestImage;
      evaluator = guestEvaluator;
    };
  site = mkBrowserSite { };
  python = pkgs.python3.withPackages (ps: [ ps.playwright ]);
  serve = pkgs.writeShellApplication {
    name = "browser-serve";
    runtimeInputs = [ pkgs.python3 ];
    text = ''exec python3 ${../browser}/serve.py ${site} "$@"'';
  };
  smoke = pkgs.writeShellApplication {
    name = "browser-smoke-test";
    runtimeInputs = [
      python
      pkgs.chromium
    ];
    text = ''exec ${python}/bin/python3 ${../browser}/smoke.py ${site} --chromium ${pkgs.chromium}/bin/chromium "$@"'';
  };
  cacheSmoke = pkgs.writeShellApplication {
    name = "browser-cache-smoke-test";
    runtimeInputs = [
      python
      pkgs.chromium
    ];
    text = ''exec ${python}/bin/python3 ${../browser}/cache-smoke.py --chromium ${pkgs.chromium}/bin/chromium "$@"'';
  };
  graphicalSmoke = pkgs.writeShellApplication {
    name = "browser-graphical-smoke-test";
    runtimeInputs = [
      python
      pkgs.chromium
    ];
    text = ''exec ${python}/bin/python3 ${../browser}/graphical-smoke.py --chromium ${pkgs.chromium}/bin/chromium "$@"'';
  };
  chunkSmoke = pkgs.writeShellApplication {
    name = "browser-chunk-smoke-test";
    runtimeInputs = [
      python
      pkgs.chromium
    ];
    text = ''exec ${python}/bin/python3 ${../browser}/chunk-smoke.py --chromium ${pkgs.chromium}/bin/chromium "$@"'';
  };
  nativeProof = pkgs.writeShellApplication {
    name = "browser-native-proof";
    runtimeInputs = [
      pkgs.python3
      engines.nativeQemu
    ];
    text = ''
      manifest=$(python3 -c 'import json, pathlib, sys; root = pathlib.Path(sys.argv[1]); print(root / json.loads((root / "channel.json").read_text())["manifest"]["url"])' ${site})
      exec python3 ${../browser}/launch.py \
        --manifest "$manifest" \
        --pack ${engines.firmware} --disk ${image}/redox.img \
        --engine-dir ${engines.engine} \
        --qemu ${engines.nativeQemu}/bin/qemu-system-x86_64 \
        --native-provenance ${engines.nativeProvenance} "$@"
    '';
  };
  snapshot = pkgs.writeShellApplication {
    name = "browser-snapshot";
    runtimeInputs = [
      pkgs.python3
      engines.nativeQemu
    ];
    text = ''
      manifest=$(python3 -c 'import json, pathlib, sys; root = pathlib.Path(sys.argv[1]); print(root / json.loads((root / "channel.json").read_text())["manifest"]["url"])' ${site})
      exec python3 ${../browser}/snapshot.py \
        --manifest "$manifest" \
        --pack ${engines.firmware} --disk ${image}/redox.img \
        --engine-dir ${engines.engine} --efi ${image}/boot/BOOTX64.EFI \
        --qemu ${engines.nativeQemu}/bin/qemu-system-x86_64 \
        --native-provenance ${engines.nativeProvenance} "$@"
    '';
  };
  autobootChecks = import ../tests/autoboot.nix {
    inherit pkgs;
    inherit (self.inputs) bootloader-src;
    bootloaderVariants = {
      inherit (modularPkgs.system)
        bootloader
        bootloaderAutoboot
        bootloaderLive
        bootloaderLiveAutoboot
        ;
    };
  };
in
{
  packages = {
    browser-image = image;
    browser-graphical-image = graphicalImage;
    browser-site = site;
    browser-engine = engines.engine;
    browser-native-qemu = engines.nativeQemu;
    browser-native-provenance = engines.nativeProvenance;
    browser-firmware = engines.firmware;
    browser-vendor = engines.vendor;
    browser-build-engine = engines.buildEngine;
    browser-demo-flush = flush;
    browser-serve = serve;
    browser-smoke-test = smoke;
    browser-cache-smoke-test = cacheSmoke;
    browser-graphical-smoke-test = graphicalSmoke;
    browser-chunk-smoke-test = chunkSmoke;
    browser-native-proof = nativeProof;
    browser-snapshot = snapshot;
    browser-cache = downloadableCache;
    snix-wasm = evaluator;
    binaryCacheFixture = cacheTests.cache;
    cacheRuntimeFixtureCache = runtimeFixture.cache;
    cache-closure-fixture = runtimeFixture.package;
  };
  apps = {
    browser-serve = {
      type = "app";
      program = "${serve}/bin/browser-serve";
    };
    browser-smoke-test = {
      type = "app";
      program = "${smoke}/bin/browser-smoke-test";
    };
    browser-cache-smoke-test = {
      type = "app";
      program = "${cacheSmoke}/bin/browser-cache-smoke-test";
    };
    browser-graphical-smoke-test = {
      type = "app";
      program = "${graphicalSmoke}/bin/browser-graphical-smoke-test";
    };
    browser-chunk-smoke-test = {
      type = "app";
      program = "${chunkSmoke}/bin/browser-chunk-smoke-test";
    };
    browser-native-proof = {
      type = "app";
      program = "${nativeProof}/bin/browser-native-proof";
    };
    browser-snapshot = {
      type = "app";
      program = "${snapshot}/bin/browser-snapshot";
    };
    browser-build-engine = {
      type = "app";
      program = "${engines.buildEngine}/bin/build-browser-engine";
    };
    browser-delivery-tests = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "browser-delivery-tests" ''
          exec ${pkgs.python3}/bin/python3 ${../browser}/test_delivery.py "$@"
        ''
      );
    };
  };
  checks = autobootChecks // {
    vm-policy = import ../pkgs/infrastructure/vm-policy-test.nix { inherit pkgs lib; };
    binary-cache-contracts = cacheTests.contracts;
    binary-cache-closure = cacheTests.closure;
    browser-delivery =
      pkgs.runCommand "redox-browser-delivery-contracts" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          python3 ${../browser}/test_delivery.py
          touch $out
        '';
    browser-smoke =
      pkgs.runCommand "redox-browser-real-guest-smoke"
        {
          nativeBuildInputs = [
            python
            pkgs.chromium
          ];
        }
        ''
          mkdir -p $out
          ${python}/bin/python3 ${../browser}/smoke.py ${site} --chromium ${pkgs.chromium}/bin/chromium --output $out
        '';
  };
  legacyPackages = {
    inherit mkBrowserSite browserSystem graphicalSystem;
    browserEngines = engines;
    cacheRuntimeFixture = runtimeFixture;
  };
}
