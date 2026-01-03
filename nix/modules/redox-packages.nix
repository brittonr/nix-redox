# Flake-parts module for RedoxOS packages
#
# This module provides a standardized way to expose RedoxOS packages
# through flake-parts. It can be imported by other flakes to access
# the RedoxOS build infrastructure.
#
# Usage in flake.nix:
#   imports = [
#     ./nix/modules/redox-packages.nix
#   ];
#
#   perSystem = { config, ... }: {
#     # Access packages via config.redox.packages.*
#     packages.ion = config.redox.packages.userspace.ion;
#   };

{ lib, flake-parts-lib, ... }:

let
  inherit (lib) mkOption types;
  inherit (flake-parts-lib) mkPerSystemOption;

in
{
  options.perSystem = mkPerSystemOption (
    {
      config,
      pkgs,
      system,
      ...
    }:
    {
      options.redox = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to enable RedoxOS package builds";
        };

        target = mkOption {
          type = types.str;
          default = "x86_64-unknown-redox";
          description = "The Redox target triple";
        };

        packages = mkOption {
          type = types.attrsOf types.package;
          default = { };
          description = "All RedoxOS packages";
          readOnly = true;
        };

        lib = mkOption {
          type = types.attrs;
          default = { };
          description = "RedoxOS library functions";
          readOnly = true;
        };
      };
    }
  );

  config = {
    perSystem =
      {
        config,
        pkgs,
        lib,
        self',
        inputs',
        ...
      }:
      lib.mkIf config.redox.enable {
        # The actual package definitions are in the main flake.nix
        # This module just provides the structure for accessing them
        redox = {
          # Packages are populated by the main flake configuration
          # This provides a clean interface for external consumers
        };
      };
  };
}
