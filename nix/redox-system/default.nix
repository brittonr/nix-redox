# RedoxOS Module System - Top-Level Entry Point
#
# This is the main entry point for the RedoxOS module system, inspired by NixOS modules.
# It provides a declarative interface for configuring RedoxOS systems.
#
# Architecture:
#   1. redoxSystem function takes modules and packages
#   2. eval.nix evaluates modules using lib.evalModules
#   3. Base modules from module-list.nix provide core options and defaults
#   4. User modules override and extend base configuration
#   5. Final config includes build outputs (diskImage, initfs, toplevel)
#
# Inspired by:
#   - NixOS modules: Declarative configuration with options and config
#   - Disko: Filesystem/disk configuration patterns
#   - Wrappers pattern: Chainable extension via .extend
#
# Example usage in flake.nix:
#   redoxSystem = import ./nix/redox-system { inherit lib; };
#
#   mySystem = redoxSystem.redoxSystem {
#     modules = [
#       ./my-redox-config.nix
#       { config.system.hostname = "myredox"; }
#     ];
#     pkgs = crossPackages;  # All Redox cross-compiled packages
#     hostPkgs = pkgs;        # nixpkgs for build machine
#   };
#
#   # Access outputs:
#   diskImage = mySystem.diskImage;
#   config = mySystem.config;
#
#   # Chain additional modules (wrappers pattern):
#   withGraphics = mySystem.extend { config.graphics.enable = true; };

{ lib }:

let
  # Import the module evaluator
  evaluator = import ./eval.nix { inherit lib; };

  # The main redoxSystem builder
  # Takes user modules and package sets, returns evaluated system
  redoxSystem =
    {
      # List of module files or attrsets
      modules,
      # Flat attrset of all cross-compiled Redox packages
      # Expected: { kernel, bootloader, base, ion, helix, ... }
      pkgs,
      # nixpkgs for the build machine (for host tools like redoxfs)
      hostPkgs,
      # Extra arguments passed to all modules (via specialArgs)
      # Useful for passing custom values like sourceInfo, version, etc.
      extraSpecialArgs ? { },
    }:
    let
      # Evaluate the module system
      evaluated = evaluator.evalRedoxModules {
        inherit modules pkgs hostPkgs;
        specialArgs = extraSpecialArgs;
      };

      # Extract the evaluated configuration
      inherit (evaluated) config options;

      # Build outputs - these are defined by modules but exposed at top level
      # for convenience (following NixOS pattern)
      diskImage = config.system.build.diskImage;
      initfs = config.system.build.initfs;
      toplevel = config.system.build.toplevel;

    in
    {
      # Core outputs
      inherit
        config
        options
        diskImage
        initfs
        toplevel
        ;

      # Wrappers-style chainable extension
      # Allows adding modules after initial evaluation:
      #   system.extend { config.services.enable = true; }
      # This creates a new system with the additional module
      extend =
        extraModule:
        redoxSystem {
          modules = modules ++ [ extraModule ];
          inherit pkgs hostPkgs;
          extraSpecialArgs = extraSpecialArgs;
        };

      # Type metadata (useful for debugging and introspection)
      _type = "redox-system";
      _module = {
        inherit modules pkgs hostPkgs;
      };
    };

in
{
  inherit redoxSystem;

  # Version info (for compatibility checking)
  version = "0.1.0";

  # Re-export evaluator for advanced use cases
  inherit (evaluator) evalRedoxModules;
}
