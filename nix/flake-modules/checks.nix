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
  ...
}:
let
  packages = self'.packages;

  # Import the module system test suite
  moduleSystemTests = import ../tests { inherit pkgs lib; };

in
{
  checks =
    {
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

      # snix
      snix-build = packages.snix;

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
