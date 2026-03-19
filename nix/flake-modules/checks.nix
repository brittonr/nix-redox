# RedoxOS checks module (adios-flake)
#
# Provides build and quality checks organized in tiers:
#
#   Tier 1 — eval (seconds):   Module system tests with mock packages
#   Tier 2 — host (minutes):   + snix host-side unit tests, devshells, host tools
#   Tier 3 — cross (minutes):  + cross-compiled packages
#   Tier 4 — vm (many minutes): + boot test, functional test, bridge test
#
# Quick iteration:
#   nix build .#checks.x86_64-linux.tier-eval    # seconds
#   nix build .#checks.x86_64-linux.tier-host    # minutes
#   nix build .#checks.x86_64-linux.tier-cross   # many minutes
#   nix build .#checks.x86_64-linux.tier-vm      # many minutes (needs KVM)
#
# Individual checks:
#   nix build .#checks.x86_64-linux.eval-profile-default
#   nix build .#checks.x86_64-linux.snix-test
#   nix build .#checks.x86_64-linux.functional-test
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
      ws = buildFromUnitGraph {
        inherit pkgs;
        src = ../../snix-redox;
        resolvedJson = ../../snix-redox/build-plan.json;
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
    snix-test = snixHostTests.test.check."snix-redox";

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
  # Full VM boot + test execution.
  vmChecks = {
    boot-test = packages.bootTest;
    functional-test = packages.functionalTest;
    multi-user-test = packages.multi-user-test;
    bridge-test = packages.bridgeTest;
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
    // vmChecks

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

      tier-vm = mkTierCheck "vm" "Full VM boot and integration tests" vmChecks;
    };
}
