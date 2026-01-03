# Default flake-parts module for RedoxOS
#
# This module imports all other modules to provide the complete
# RedoxOS build infrastructure. Use this for the standard setup.
#
# For fine-grained control, import individual modules from:
# - ./packages.nix
# - ./devshells.nix
# - ./checks.nix
# - ./apps.nix
# - ./formatter.nix
# - ./overlays.nix
# - ./nixos-module.nix
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules ];

{ ... }:

{
  imports = [
    ./packages.nix
    ./devshells.nix
    ./checks.nix
    ./apps.nix
    ./formatter.nix
    ./overlays.nix
    ./nixos-module.nix
  ];
}
