# RedoxOS Module Evaluator
#
# This module provides the core evaluation logic for the RedoxOS module system.
# It uses Nix's lib.evalModules to merge and evaluate configuration modules.
#
# Architecture:
#   1. Takes user modules + base modules from module-list.nix
#   2. Provides specialArgs: pkgs (Redox packages), hostPkgs (nixpkgs), redoxSystemLib
#   3. Evaluates using lib.evalModules (same as NixOS, home-manager, etc.)
#   4. Returns { config, options, ... } for use by default.nix
#
# Module evaluation order:
#   1. Base modules (module-list.nix) set up core options and defaults
#   2. User modules override and extend configuration
#   3. lib.evalModules merges everything using the Nix module system
#
# Available in modules via specialArgs:
#   - pkgs: Cross-compiled Redox packages (kernel, base, ion, etc.)
#   - hostPkgs: Build machine packages (redoxfs, python, etc.)
#   - redoxSystemLib: Helper functions from lib.nix
#
# Example module:
#   { config, lib, pkgs, hostPkgs, redoxSystemLib, ... }:
#   {
#     config.system.hostname = "myredox";
#     config.environment.packages = with pkgs; [ ion helix ];
#   }

{ lib }:

let
  # Import base module list
  baseModules = import ./module-list.nix;

in
{
  # Main evaluation function
  # Takes modules and package sets, returns lib.evalModules result
  evalRedoxModules =
    {
      # User-provided modules (list of paths or attrsets)
      modules,
      # Cross-compiled Redox packages
      pkgs,
      # Host nixpkgs
      hostPkgs,
      # Additional special arguments (merged with our defaults)
      specialArgs ? { },
    }:
    let
      # Import lib.nix with hostPkgs (for tools like python)
      redoxSystemLib = import ./lib.nix {
        inherit lib;
        pkgs = hostPkgs; # lib.nix uses host tools
      };

      # Merge user specialArgs with our required args
      # This allows users to pass custom values (version, sourceInfo, etc.)
      # while we provide the core Redox-specific values
      fullSpecialArgs = specialArgs // {
        inherit pkgs hostPkgs redoxSystemLib;
        # Also provide lib explicitly (some modules expect it)
        inherit lib;
      };

    in
    # Evaluate using lib.evalModules (standard Nix module system)
    # This handles option declarations, merging, and evaluation
    lib.evalModules {
      # Pass pkgs and hostPkgs as specialArgs (not as modules)
      # This makes them available to all modules without needing to import
      specialArgs = fullSpecialArgs;

      # Combine base modules with user modules
      # Base modules come first (lower priority)
      # User modules come last (higher priority, can override)
      modules = baseModules ++ modules;

      # Note: Module checking is handled by _module.check (default: true)
    };
}
