# RedoxOS checks module (adios-flake)
#
# Provides build and quality checks organized in tiers:
#
#   Tier 1 — eval (seconds):   Module system tests with mock packages
#   Tier 2 — host (minutes):   + snix host-side unit tests, devshells, host tools
#   Tier 3 — cross (minutes):  + cross-compiled packages
#   Tier 4 — vm (sub-tiered by cost, needs KVM):
#     fast:  8 tests — boot, functional, daemons, schemes (<3 min each)
#     full: 13 tests — + rebuild pipelines, networking (3-10 min each)
#     heavy: 16 tests — + self-hosting, parallel builds (15-30 min each)
#
# Quick iteration:
#   nix build .#checks.x86_64-linux.tier-eval      # seconds
#   nix build .#checks.x86_64-linux.tier-host      # minutes
#   nix build .#checks.x86_64-linux.tier-cross     # many minutes
#   nix build .#checks.x86_64-linux.tier-vm        # = tier-vm-fast (backward compat)
#   nix build .#checks.x86_64-linux.tier-vm-fast   # 8 quick VM tests
#   nix build .#checks.x86_64-linux.tier-vm-full   # 13 VM tests (+ rebuild, network)
#   nix build .#checks.x86_64-linux.tier-vm-heavy  # 16 VM tests (+ self-hosting)
#   nix build .#checks.x86_64-linux.tier-vm-all    # all 16 VM tests
#
# Individual checks:
#   nix build .#checks.x86_64-linux.eval-profile-default
#   nix build .#checks.x86_64-linux.snix-test
#   nix build .#checks.x86_64-linux.functional-test
#   nix build .#checks.x86_64-linux.network-test
#
# All checks:
#   nix flake check

{
  pkgs,
  lib,
  self',
  self,
  ...
}:
let
  packages = self'.packages;

  # Import the module system test suite
  moduleSystemTests = import ../tests { inherit pkgs lib; };

  # Host-side snix tests via unit2nix
  # Builds snix-redox per-crate for x86_64-unknown-linux-gnu and runs #[test]s.
  # The build plan was generated with:
  #   cd snix-redox && CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu \
  #     unit2nix --include-dev --force -o build-plan.json
  # (with test=false temporarily removed from Cargo.toml)
  snixHostTests =
    let
      unit2nix = self.inputs.unit2nix;
      buildFromUnitGraph = unit2nix.lib.${pkgs.system}.buildFromUnitGraph;
      snixUpstreamSource = import ../pkgs/infrastructure/snix-upstream-source.nix {
        inherit pkgs;
      };
      # Compose snix-redox source with upstream crates (same as cross-build)
      snixCombinedSrc = pkgs.runCommand "snix-redox-combined-src" { } ''
        cp -r ${../../snix-redox} $out
        chmod -R u+w $out
        rm -f $out/upstream
        cp -r ${snixUpstreamSource} $out/upstream
      '';
      ws = buildFromUnitGraph {
        inherit pkgs;
        src = snixCombinedSrc;
        resolvedJson = ../../snix-redox/build-plan.json;
        extraCrateOverrides = {
          snix-castore = _: {
            nativeBuildInputs = [ pkgs.protobuf ];
            PROTO_ROOT = snixUpstreamSource;
            SNIX_BUILD_SANDBOX_SHELL = "/bin/sh";
          };
          snix-store = _: {
            nativeBuildInputs = [ pkgs.protobuf ];
            PROTO_ROOT = snixUpstreamSource;
            SNIX_BUILD_SANDBOX_SHELL = "/bin/sh";
          };
          snix-build = _: {
            nativeBuildInputs = [ pkgs.protobuf ];
            PROTO_ROOT = snixUpstreamSource;
            SNIX_BUILD_SANDBOX_SHELL = "/bin/sh";
          };
          prost-wkt-types = _: {
            nativeBuildInputs = [ pkgs.protobuf ];
          };
          # snix-redox tests construct SnixStoreIO which creates a reqwest
          # client that needs CA certificates. Tests don't do HTTP but
          # reqwest with native-roots panics on missing certs at client init.
          snix-redox = attrs: {
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          };
        };
      };
    in
    ws;

  # ── Tier 1: eval (seconds) ──────────────────────────────────────
  # Module system tests with mock packages. No builds, just Nix evaluation.
  evalChecks =
    moduleSystemTests.eval
    // moduleSystemTests.types
    // moduleSystemTests.artifacts
    // moduleSystemTests.lib;

  # ── Tier 2: host (minutes) ──────────────────────────────────────
  # Native host-side builds and tests. No cross-compilation.
  hostChecks = {
    # DevShell validation
    devshell-default = self'.devShells.default;
    devshell-minimal = self'.devShells.minimal;

    # Host tools (native builds)
    cookbook-build = packages.cookbook;
    redoxfs-build = packages.redoxfs;
    installer-build = packages.installer;

    # snix host-side unit tests (502 tests, runs on linux, no VM needed)
    snix-test = snixHostTests.test.check."snix-redox".overrideAttrs (old: {
      # Upstream snix-glue Fetcher::new() creates a reqwest Client that
      # needs CA certificates (rustls-platform-verifier). Tests don't do HTTP
      # but reqwest panics without certs at client init.
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    });

    # snix clippy lint
    snix-clippy = snixHostTests.clippy.allWorkspaceMembers;
  };

  # ── Tier 3: cross (many minutes) ───────────────────────────────
  # Cross-compiled packages for x86_64-unknown-redox.
  crossChecks = {
    # Core system components
    relibc-build = packages.relibc;
    kernel-build = packages.kernel;
    bootloader-build = packages.bootloader;
    base-build = packages.base;

    # Userspace packages
    ion-build = packages.ion;
    uutils-build = packages.uutils;
    sodium-build = packages.sodium;
    netutils-build = packages.netutils;

    # snix (cross-compiled for Redox)
    snix-build = packages.snix;

    # CLI tools
    ripgrep-cross = packages.ripgrep;
    dust-cross = packages.dust;
    hexyl-cross = packages.hexyl;
    shellharden-cross = packages.shellharden;
    smith-cross = packages.smith;
    exampled-cross = packages.exampled;
    tokei-cross = packages.tokei;
    zoxide-cross = packages.zoxide;
    lsd-cross = packages.lsd;
    bat-cross = packages.bat;
    fd-cross = packages.fd;

    # Complete system image
    redox-default-build = packages.redox-default;
  };

  # ── Tier 4: vm (many minutes, needs KVM) ───────────────────────
  # Full VM boot + test execution, split into sub-tiers by cost.

  # Fast: core smoke tests + quick offline daemon/scheme tests (<3 min each)
  vmChecksFast = {
    boot-test = packages.bootTest;
    functional-test = packages.functionalTest;
    multi-user-test = packages.multi-user-test;
    bridge-test = packages.bridgeTest;
    scheme-daemon-test = packages.scheme-daemon-test;
    iroh-test = packages.iroh-test;
    scheme-native-test = packages.scheme-native-test;
    boot-generation-select-test = packages.boot-generation-select-test;
  };

  # Full: medium-duration rebuild/upgrade tests + QEMU SLiRP network tests (3-10 min each)
  vmChecksFull = vmChecksFast // {
    rebuild-generations-test = packages.rebuild-generations-test;
    e2e-rebuild-test = packages.e2e-rebuild-test;
    network-test = packages.networkTest;
    network-install-test = packages.networkInstallTest;
    channel-update-test = packages.channelUpdateTest;
  };

  # Heavy: self-hosting, parallel builds, bridge rebuild (15-30 min each)
  vmChecksHeavy = vmChecksFull // {
    bridge-rebuild-test = packages.bridgeRebuildTest;
    self-hosting-test = packages.self-hosting-test;
    parallel-build-test = packages.parallel-build-test;
  };

  # ── Tier aggregation helpers ────────────────────────────────────
  # Creates a derivation that depends on all checks in a tier.
  # Building tier-X ensures all tier-X checks pass.
  mkTierCheck =
    name: description: checks:
    pkgs.runCommand "tier-${name}"
      {
        preferLocalBuild = true;
        passthru = { inherit checks; };
      }
      ''
        echo "=== Tier: ${name} ==="
        echo "${description}"
        echo ""
        echo "All ${toString (builtins.length (builtins.attrNames checks))} checks passed:"
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (n: drv: ''
            echo "  ✓ ${n}"
          '') checks
        )}
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (n: drv: ''
            # Reference the derivation to force it to build
            test -e ${drv} || true
          '') checks
        )}
        touch $out
      '';

in
{
  checks =
    # All individual checks (flat namespace for nix flake check)
    evalChecks
    // hostChecks
    // crossChecks
    // vmChecksHeavy # Heavy is cumulative — includes fast + full + heavy

    # Tier aggregation targets
    // {
      tier-eval =
        mkTierCheck "eval" "Module system tests (evaluation, types, artifacts, library functions)"
          evalChecks;

      tier-host =
        mkTierCheck "host" "Host-side builds and tests (devshells, host tools, snix unit tests)"
          (evalChecks // hostChecks);

      tier-cross = mkTierCheck "cross" "Cross-compiled packages for Redox" (
        evalChecks // hostChecks // crossChecks
      );

      # VM sub-tiers by cost
      tier-vm-fast =
        mkTierCheck "vm-fast" "Quick VM tests: boot, functional, daemons, schemes"
          vmChecksFast;
      tier-vm-full = mkTierCheck "vm-full" "VM tests + rebuild pipelines and networking" vmChecksFull;
      tier-vm-heavy =
        mkTierCheck "vm-heavy" "All VM tests including self-hosting and parallel builds"
          vmChecksHeavy;
      tier-vm-all = mkTierCheck "vm-all" "All 16 VM tests" vmChecksHeavy;

      # Backward compatibility: tier-vm = tier-vm-fast
      tier-vm = mkTierCheck "vm" "Quick VM tests (alias for tier-vm-fast)" vmChecksFast;
    };
}
