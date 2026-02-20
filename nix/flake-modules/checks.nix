# Flake-parts module for RedoxOS checks
#
# This module provides comprehensive build and quality checks:
# - Formatting: Via treefmt-nix (automatic)
# - Pre-commit: Via git-hooks.nix (automatic)
# - Module system tests: Evaluation, types, artifacts, library functions
# - Build checks: Ensures key packages build successfully
# - DevShell validation: Ensures development shells build
# - Boot test: Verifies complete system boots
#
# Usage:
#   nix flake check                                      - Run all checks
#   nix build .#checks.x86_64-linux.eval-profile-default - Module system evaluation test
#   nix build .#checks.x86_64-linux.type-invalid-network-mode - Type validation test
#   nix build .#checks.x86_64-linux.artifact-rootTree-passwd - Build artifact test
#   nix build .#checks.x86_64-linux.lib-passwd-format    - Library function test

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      lib,
      config,
      self',
      ...
    }:
    let
      # Get packages from the packages module
      packages = self'.packages;

      # Import the module system test suite
      moduleSystemTests = import ../tests { inherit pkgs lib; };

    in
    {
      checks = {
        # === Module System Tests ===
        # Layer 1: Evaluation tests (fast, use mock packages)
        # These verify the module system evaluates correctly without building cross-compiled packages
      }
      // moduleSystemTests.eval
      // {
        # Layer 2: Type validation tests
        # These verify Korora types reject invalid inputs and accept valid ones
      }
      // moduleSystemTests.types
      // {
        # Layer 3: Build artifact tests
        # These verify built outputs contain expected files/content
      }
      // moduleSystemTests.artifacts
      // {
        # Layer 4: Library function tests
        # These verify helper functions (passwd, group formatting) work correctly
      }
      // moduleSystemTests.lib
      // {
        # === DevShell Validation ===
        # Ensures all development shells can be built
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

        # snix - Nix evaluator for Redox OS
        snix-build = packages.snix;

        # Complete system images (from module system profiles)
        redox-default-build = packages.redox-default;

        # Boot test - verifies the complete system boots successfully
        # This is the script package; run interactively with: nix run .#boot-test
        # For CI, run outside the sandbox with KVM access
        boot-test = packages.bootTest;

        # Functional test - runs ~40 in-guest tests after boot
        # Run interactively with: nix run .#functional-test
        functional-test = packages.functionalTest;
      };
    };
}
