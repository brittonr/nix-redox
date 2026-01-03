# Flake-parts module for exporting flakeModules
#
# This module exports all RedoxOS flake-parts modules for use by other flakes.
# Other projects can import these modules to get RedoxOS build infrastructure.
#
# Usage in other flakes:
#   {
#     inputs.redox.url = "github:user/redox";
#
#     outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
#       imports = [
#         inputs.redox.flakeModules.default
#         # Or specific modules:
#         inputs.redox.flakeModules.packages
#         inputs.redox.flakeModules.devshells
#       ];
#     };
#   }

{ self, inputs, ... }:

{
  imports = [
    inputs.flake-parts.flakeModules.flakeModules
  ];

  flake.flakeModules = {
    # Default module - includes packages, devshells, checks, apps, formatter
    default = ./default.nix;

    # Individual modules for fine-grained control
    packages = ./packages.nix;
    devshells = ./devshells.nix;
    checks = ./checks.nix;
    apps = ./apps.nix;
    formatter = ./formatter.nix;
    overlays = ./overlays.nix;
    nixos-module = ./nixos-module.nix;
  };
}
