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

  # Per-crate cross-compilation test: build ripgrep for Redox using
  # unit2nix + buildRustCrate instead of cargo build.
  # Each of ripgrep's 33 crates is a separate Nix derivation with caching.
  ripgrepCrossTest =
    let
      inputs = self.inputs;
      env = import ./redox-env.nix {
        inherit pkgs lib inputs;
        system = pkgs.system;
      };
      unit2nix = inputs.unit2nix;
      buildFromUnitGraph = import "${unit2nix}/lib/build-from-unit-graph.nix";
      redoxBRC = import ../lib/redox-buildRustCrate.nix {
        inherit pkgs lib;
        inherit (env) rustToolchain;
        inherit (env.modularPkgs.system) relibc;
        inherit (env.redoxLib) stubLibs;
      };
      ws = buildFromUnitGraph {
        inherit pkgs;
        src = inputs.ripgrep-src;
        resolvedJson = ../pkgs/infrastructure/ripgrep-redox-plan.json;
        buildRustCrateForPkgs = _: redoxBRC;
        skipStalenessCheck = true;
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

    # Per-crate cross-compilation: ripgrep for Redox (33 crates, each cached)
    ripgrep-cross = ripgrepCrossTest.workspaceMembers.ripgrep.build;

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
