# Flake-parts module for RedoxOS formatter
#
# This module provides the formatter configuration.
# Currently uses nixfmt-rfc-style which is the recommended Nix formatter.
#
# For more advanced formatting (multiple languages), consider adding
# treefmt-nix integration which can format Nix, Rust, TOML, etc.
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/formatter.nix ];
#
# Format files:
#   nix fmt

{ self, inputs, ... }:

{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt-rfc-style;
    };
}
