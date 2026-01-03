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
    # Default module - includes all functionality
    default = ./default.nix;

    # Core modules
    toolchain = ./toolchain.nix;
    packages = ./packages.nix;
    config = ./config.nix;

    # Development experience
    devshells = ./devshells.nix;
    treefmt = ./treefmt.nix;
    git-hooks = ./git-hooks.nix;

    # CI/CD
    checks = ./checks.nix;
    apps = ./apps.nix;

    # Integration
    overlays = ./overlays.nix;
    nixos-module = ./nixos-module.nix;
  };
}
