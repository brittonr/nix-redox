# Default flake-parts module for RedoxOS
#
# This module imports all other modules to provide the complete
# RedoxOS build infrastructure. Use this for the standard setup.
#
# For fine-grained control, import individual modules from:
# - ./toolchain.nix  - Rust toolchain configuration
# - ./packages.nix   - Package definitions
# - ./config.nix     - Configuration options
# - ./devshells.nix  - Development shells
# - ./treefmt.nix    - Code formatting
# - ./git-hooks.nix  - Pre-commit hooks
# - ./checks.nix     - CI checks
# - ./apps.nix       - Runnable applications
# - ./overlays.nix   - Nixpkgs overlays
# - ./nixos-module.nix - NixOS integration
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules ];

{ ... }:

{
  imports = [
    ./toolchain.nix
    ./config.nix
    ./packages.nix
    ./devshells.nix
    ./treefmt.nix
    ./git-hooks.nix
    ./checks.nix
    ./apps.nix
    ./overlays.nix
    ./nixos-module.nix
  ];
}
