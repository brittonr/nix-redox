# RedoxOS code formatting module (adios-flake)
#
# Uses treefmt-nix.lib.evalModule directly instead of the flake-parts module.
#
# Usage:
#   nix fmt           # Format all files
#   nix flake check   # Includes format verification
#
# Formatters configured:
#   - nixfmt-rfc-style: Nix files (RFC-style formatting)
#   - shfmt: Shell scripts

{
  pkgs,
  self,
  ...
}:
let
  treefmtEval = self.inputs.treefmt-nix.lib.evalModule pkgs {
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

    # Exclude vendor directories, generated files, and files with bash heredocs
    # that nixfmt would break by re-indenting terminators
    settings.global.excludes = [
      "vendor/*"
      "vendor-combined/*"
      "result*"
      ".git/*"
      "nix/redox-system/profiles/self-hosting-test.nix"
    ];
  };

in
{
  formatter = treefmtEval.config.build.wrapper;
  checks = {
    formatting = treefmtEval.config.build.check self;
  };
}
