# RedoxOS Module System Test Suite
#
# Comprehensive tests for the adios-based module system at nix/redox-system/.
# Tests are organized in layers:
#
#   Layer 1 (eval.nix): Module evaluation tests with mock packages
#   Layer 2 (types.nix): Type validation tests (Korora type system)
#   Layer 3 (artifacts.nix): Build artifact tests (rootTree, initfs content)
#   Layer 4 (lib.nix): Library function tests (passwd, group formatting)
#
# Usage:
#   nix build .#checks.x86_64-linux.eval-profile-default
#   nix build .#checks.x86_64-linux.type-invalid-network-mode
#   nix build .#checks.x86_64-linux.artifact-rootTree-passwd
#   nix build .#checks.x86_64-linux.lib-passwd-format
#
# Or run all tests:
#   nix flake check

{ pkgs, lib }:

let
  # Import test layers
  evalTests = import ./eval.nix { inherit pkgs lib; };
  typeTests = import ./types.nix { inherit pkgs lib; };
  artifactTests = import ./artifacts.nix { inherit pkgs lib; };
  libTests = import ./lib.nix { inherit pkgs lib; };

  # Add layer prefix to test names for clarity
  prefixTests =
    prefix: tests: lib.mapAttrs' (name: value: lib.nameValuePair "${prefix}-${name}" value) tests;

in
{
  # Export all tests with layer prefixes
  eval = prefixTests "eval" evalTests;
  types = prefixTests "type" typeTests;
  artifacts = prefixTests "artifact" artifactTests;
  lib = prefixTests "lib" libTests;

  # Convenience: flat namespace for direct access
  all =
    (prefixTests "eval" evalTests)
    // (prefixTests "type" typeTests)
    // (prefixTests "artifact" artifactTests)
    // (prefixTests "lib" libTests);

  # Meta information
  meta = {
    description = "RedoxOS module system test suite";
    layers = {
      eval = "Module evaluation tests (fast, mock packages)";
      types = "Type validation tests (Korora type system)";
      artifacts = "Build artifact tests (file content verification)";
      lib = "Library function tests (passwd/group formatting)";
    };
    count = {
      eval = builtins.length (builtins.attrNames evalTests);
      types = builtins.length (builtins.attrNames typeTests);
      artifacts = builtins.length (builtins.attrNames artifactTests);
      lib = builtins.length (builtins.attrNames libTests);
      total = builtins.length (builtins.attrNames (evalTests // typeTests // artifactTests // libTests));
    };
  };
}
