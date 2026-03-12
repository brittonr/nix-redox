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
      # hostPkgs must have buildPackages pointing to itself (recursively)
      # so that mkBuiltByPackageIdByPkgs never escapes back to unmarked pkgs.
      hostPkgs = pkgs // {
        __isHostPkgs = true;
        buildPackages = hostPkgs; # self-referential: always stays in host set
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

      # Shared crate-level overrides for cross-builds.
      #
      # rustix: The build plan resolves deps for Redox, which excludes
      # linux_raw_sys.  But when a package has clap as a buildDependency,
      # rustix gets built for the HOST (Linux) via hostBRC.  The host
      # build.rs sees CARGO_CFG_TARGET_OS=linux and emits linux_like +
      # linux_kernel cfg flags, whose code paths reference linux_raw_sys.
      #
      # Fix: force libc backend (CARGO_CFG_RUSTIX_USE_LIBC=1) to avoid
      # the linux_raw backend, AND patch build.rs to suppress linux_like /
      # linux_kernel when libc is forced — those code paths in the libc
      # backend also reference linux_raw_sys for constants.
      #
      # Only needed for packages whose plans lack linux_raw_sys.
      # Packages with older rustix versions that include linux_raw_sys
      # in the plan (e.g., bat with rustix 0.38.11) don't need this.
      #
      # faccess: uses faccessat(2) on cfg(unix), but relibc doesn't
      # implement faccessat.  Redirect Redox to the generic fallback.
      cratePatches = {
        # rustix override for plans that exclude linux_raw_sys
        rustixOverride = {
          rustix = _: {
            CARGO_CFG_RUSTIX_USE_LIBC = "1";
            postPatch = ''
              # Guard linux_like/linux_kernel emission on !cfg_use_libc.
              # When libc is forced (cross-build), the dep graph may not
              # include linux_raw_sys, so these code paths must be skipped.
              sed -i 's/use_feature("linux_like");/if !cfg_use_libc { use_feature("linux_like"); }/' build.rs
              sed -i 's/use_feature("linux_kernel");/if !cfg_use_libc { use_feature("linux_kernel"); }/' build.rs
            '';
          };
        };
        # faccess override for Redox (faccessat not in relibc)
        faccessOverride = {
          faccess = _: {
            postPatch = ''
              sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' src/lib.rs
              sed -i 's/#\[cfg(not(any(unix, windows)))\]/#[cfg(any(target_os = "redox", not(any(unix, windows))))]/g' src/lib.rs
            '';
          };
        };
        # fd-find override: nix crate's User/Group are gated out for Redox,
        # so fd's owner filtering module (which uses them) must be excluded.
        fdOverride = {
          fd-find = _: {
            postPatch = ''
              for f in src/filter/mod.rs src/config.rs src/main.rs src/cli.rs src/walk.rs; do
                if [ -f "$f" ]; then
                  sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' "$f"
                fi
              done
            '';
          };
        };
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
      tokei = mkCross {
        src = inputs.tokei-src;
        plan = ../pkgs/infrastructure/tokei-redox-plan.json;
      };
      zoxide = mkCross {
        src = inputs.zoxide-src;
        plan = ../pkgs/infrastructure/zoxide-redox-plan.json;
      };
      lsd = mkCross {
        src = inputs.lsd-src;
        plan = ../pkgs/infrastructure/lsd-redox-plan.json;
        extraCrateOverrides = cratePatches.rustixOverride;
      };
      bat = mkCross {
        src = inputs.bat-src;
        plan = ../pkgs/infrastructure/bat-redox-plan.json;
        # bat's rustix 0.38.11 includes linux_raw_sys in the plan,
        # so no rustix override needed.
      };
      fd = mkCross {
        src = inputs.fd-src;
        plan = ../pkgs/infrastructure/fd-redox-plan.json;
        extraCrateOverrides = cratePatches.faccessOverride // cratePatches.fdOverride;
      };
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

    # Per-crate cross-compilation: Rust packages for Redox (each crate cached).
    # Each crate is a separate Nix derivation — unchanged deps reuse store paths.
    # Packages with crate-level issues use extraCrateOverrides (see cratePatches).
    ripgrep-cross = crossBuild.ripgrep.workspaceMembers.ripgrep.build;
    dust-cross = crossBuild.dust.workspaceMembers.du-dust.build;
    hexyl-cross = crossBuild.hexyl.workspaceMembers.hexyl.build;
    shellharden-cross = crossBuild.shellharden.workspaceMembers.shellharden.build;
    smith-cross = crossBuild.smith.workspaceMembers.smith.build;
    exampled-cross = crossBuild.exampled.workspaceMembers.exampled.build;
    tokei-cross = crossBuild.tokei.workspaceMembers.tokei.build;
    zoxide-cross = crossBuild.zoxide.workspaceMembers.zoxide.build;
    lsd-cross = crossBuild.lsd.workspaceMembers.lsd.build;
    bat-cross = crossBuild.bat.workspaceMembers.bat.build;
    fd-cross = crossBuild.fd.workspaceMembers.fd-find.build;

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
