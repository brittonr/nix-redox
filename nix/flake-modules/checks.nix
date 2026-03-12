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

  # Per-crate cross-compilation for Redox via unit2nix.
  # Each crate is a separate Nix derivation with per-crate caching.
  crossBuild =
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

      # Host (native) buildRustCrate for build scripts and proc-macros.
      # These run on the build machine, not the target (Redox).
      hostBRC = pkgs.buildRustCrate.override {
        rustc = env.rustToolchain;
        cargo = env.rustToolchain;
      };

      # Cross-compilation dispatch for buildRustCrateForPkgs.
      #
      # buildFromUnitGraph calls this twice:
      # 1. With the outer pkgs → target crates (Redox cross-compilation)
      # 2. With pkgs.buildPackages → build-time crates (host Linux)
      #
      # On a native host, pkgs.buildPackages == pkgs, so both calls get
      # the same object. We break this by wrapping pkgs with a distinct
      # buildPackages that has a marker attribute.
      hostPkgs = pkgs // {
        __isHostPkgs = true;
        buildPackages = pkgs // {
          __isHostPkgs = true;
        };
      };
      crossPkgs = pkgs // {
        buildPackages = hostPkgs;
      };
      buildRustCrateForPkgs' =
        cratePkgs:
        if cratePkgs ? __isHostPkgs then
          hostBRC # Build platform: build scripts, proc-macros
        else
          redoxBRC; # Target platform: Redox cross-compilation

      # Build a package from its checked-in build plan.
      mkCross =
        {
          src,
          plan,
          extraCrateOverrides ? { },
        }:
        buildFromUnitGraph {
          inherit extraCrateOverrides;
          pkgs = crossPkgs;
          inherit src;
          resolvedJson = plan;
          buildRustCrateForPkgs = buildRustCrateForPkgs';
          skipStalenessCheck = true;
        };
    in
    {
      ripgrep = mkCross {
        src = inputs.ripgrep-src;
        plan = ../pkgs/infrastructure/ripgrep-redox-plan.json;
      };
      dust = mkCross {
        src = inputs.dust-src;
        plan = ../pkgs/infrastructure/dust-redox-plan.json;
      };
      hexyl = mkCross {
        src = inputs.hexyl-src;
        plan = ../pkgs/infrastructure/hexyl-redox-plan.json;
      };
      shellharden = mkCross {
        src = inputs.shellharden-src;
        plan = ../pkgs/infrastructure/shellharden-redox-plan.json;
      };
      smith = mkCross {
        src = inputs.smith-src;
        plan = ../pkgs/infrastructure/smith-redox-plan.json;
      };
      exampled = mkCross {
        src = inputs.exampled-src;
        plan = ../pkgs/infrastructure/exampled-redox-plan.json;
      };
      # TODO: these need proc-macro platform routing fix
      # bat, fd, lsd, tokei, zoxide
    };

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

    # Per-crate cross-compilation: Rust packages for Redox (each crate cached)
    # Packages with no proc-macro deps or complex build.rs work directly.
    # Packages with proc-macro dep chains (bat, lsd, tokei, zoxide) need
    # proper pkgsCross or a unit2nix fix for proc-macro platform routing.
    ripgrep-cross = crossBuild.ripgrep.workspaceMembers.ripgrep.build;
    dust-cross = crossBuild.dust.workspaceMembers.du-dust.build;
    hexyl-cross = crossBuild.hexyl.workspaceMembers.hexyl.build;
    shellharden-cross = crossBuild.shellharden.workspaceMembers.shellharden.build;
    smith-cross = crossBuild.smith.workspaceMembers.smith.build;
    exampled-cross = crossBuild.exampled.workspaceMembers.exampled.build;

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
