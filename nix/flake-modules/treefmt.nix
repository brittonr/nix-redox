# Flake-parts module for code formatting with treefmt-nix
#
# This module configures treefmt for consistent code formatting across
# the entire project. It replaces the manual format check with an
# integrated solution that provides both formatting and checking.
#
# Usage:
#   nix fmt           - Format all files
#   nix flake check   - Includes format verification
#
# Formatters configured:
#   - nixfmt-rfc-style: Nix files (RFC-style formatting)
#   - rustfmt: Rust files (when present)
#   - shfmt: Shell scripts

{ inputs, ... }:

{
  imports = [
    inputs.treefmt-nix.flakeModule
  ];

  perSystem =
    { pkgs, ... }:
    {
      treefmt = {
        # Root marker file for treefmt
        projectRootFile = "flake.nix";

        # Nix formatting with RFC-style
        programs.nixfmt = {
          enable = true;
          package = pkgs.nixfmt-rfc-style;
        };

        # Shell script formatting
        programs.shfmt = {
          enable = true;
          indent_size = 2;
        };

        # Settings for treefmt
        settings = {
          # Exclude vendor directories and generated files
          global.excludes = [
            "vendor/*"
            "vendor-combined/*"
            "result*"
            ".git/*"
          ];
        };
      };
    };
}
