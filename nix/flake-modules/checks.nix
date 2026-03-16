# RedoxOS checks module (adios-flake)
#
# Provides build and quality checks:
# - Module system tests (evaluation, types, artifacts, library functions)
# - Build checks for key packages
# - DevShell validation
# - Boot test, functional test, bridge test
#
# Usage:
#   nix flake check
#   nix build .#checks.x86_64-linux.eval-profile-default

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

in
{
  checks = {
    # === Module System Tests ===
  }
  // moduleSystemTests.eval
  // moduleSystemTests.types
  // moduleSystemTests.artifacts
  // moduleSystemTests.lib
  // {
    # === DevShell Validation ===
    devshell-default = self'.devShells.default;
    devshell-minimal = self'.devShells.minimal;

    # === Build Checks ===
    # Host tools (fast, native builds)
    cookbook-build = packages.cookbook;
    redoxfs-build = packages.redoxfs;
    installer-build = packages.installer;

    # Cross-compiled components (slower, but essential)
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

    # snix host-side unit tests (502 tests, runs on linux, no VM needed)
    snix-test = snixHostTests.test.check."snix-redox";

    # snix clippy lint
    snix-clippy = snixHostTests.clippy.allWorkspaceMembers;

    # Per-crate cross-compiled packages (same derivations as packages.*).
    # Aliases kept for backward compatibility with `nix build .#checks...`.
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

    # === Boot-Essential Name Validation ===
    # Catches the bug where bootEssentialNames gets out of sync with real
    # package metadata (pname / parseDrvName). Evaluates the REAL package
    # set — not mocks — so it catches drift from upstream name changes.
    #
    # Each logical package has 1-3 name variants (pname + parseDrvName
    # fallbacks). The check verifies that AT LEAST ONE variant per logical
    # package matches a real derivation. This way adding parseDrvName
    # fallbacks doesn't create false failures.
    boot-essential-names =
      let
        # Logical packages and their acceptable name variants.
        # At least one variant per group must match a real package.
        requiredGroups = [
          {
            label = "base";
            names = [
              "redox-base"
              "redox-base-unstable"
              "redox-base-percrate-unstable"
            ];
          }
          {
            label = "ion";
            names = [
              "ion-shell"
              "rust_ion-shell"
            ];
          }
          {
            label = "uutils";
            names = [ "redox-uutils" ];
          }
          {
            label = "userutils";
            names = [
              "userutils"
              "rust_userutils"
            ];
          }
          {
            label = "netutils";
            names = [
              "netutils"
              "netutils-unstable"
            ];
          }
          {
            label = "netcfg";
            names = [ "netcfg-setup" ];
          }
          {
            label = "snix";
            names = [
              "snix-redox"
              "rust_snix-redox"
            ];
          }
        ];

        # Collect pname (preferred) and parseDrvName for every real package
        realNames = lib.mapAttrsToList (
          attr: pkg:
          let
            pname = pkg.pname or null;
            parsed = (builtins.parseDrvName pkg.name).name;
          in
          {
            inherit pname parsed;
          }
        ) (lib.filterAttrs (n: v: lib.isDerivation v) packages);

        allRealNames = lib.concatMap (
          r: (if r.pname != null then [ r.pname ] else [ ]) ++ [ r.parsed ]
        ) realNames;

        # For each required group, check if any variant matches
        groupResults = map (
          g:
          let
            matched = builtins.any (n: builtins.elem n allRealNames) g.names;
          in
          {
            inherit (g) label names;
            inherit matched;
          }
        ) requiredGroups;

        failedGroups = builtins.filter (g: !g.matched) groupResults;
      in
      pkgs.runCommand "check-boot-essential-names" { } (
        ''
          set -euo pipefail
          echo "Validating bootEssentialNames against real packages..."
          echo ""
        ''
        + lib.concatMapStringsSep "\n" (
          g:
          if g.matched then
            ''echo "  OK: ${g.label} (${lib.concatStringsSep " | " g.names})"''
          else
            ''echo "  FAIL: ${g.label} — none of [${lib.concatStringsSep ", " g.names}] match any real package"''
        ) groupResults
        + ''

          echo ""
        ''
        + (
          if failedGroups == [ ] then
            ''
              echo "All boot-essential package groups verified."
              touch $out
            ''
          else
            ''
              echo "FAIL: ${toString (builtins.length failedGroups)} boot-essential group(s) have no matching package."
              echo "Fix: update bootEssentialNames in nix/redox-system/modules/build/default.nix"
              echo "Debug: nix eval .#packages.x86_64-linux.<attr> --apply"
              echo "  'drv: { pname = drv.pname or null; parsed = (builtins.parseDrvName drv.name).name; }'"
              exit 1
            ''
        )
      );

    # Complete system images
    redox-default-build = packages.redox-default;

    # Boot test
    boot-test = packages.bootTest;

    # Functional test
    functional-test = packages.functionalTest;

    # Bridge test
    bridge-test = packages.bridgeTest;
  };
}
