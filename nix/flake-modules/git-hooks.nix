# Flake-parts module for pre-commit hooks with git-hooks.nix
#
# This module configures pre-commit hooks for code quality enforcement.
# Hooks are automatically installed when entering the development shell.
#
# Configured hooks:
#   - nixfmt: Format Nix files on commit
#   - check-merge-conflict: Prevent committing merge conflict markers
#   - check-added-large-files: Prevent large file commits
#   - trailing-whitespace: Remove trailing whitespace
#   - end-of-file-fixer: Ensure files end with newline
#
# Usage:
#   nix develop  # Hooks are automatically installed
#   nix flake check  # Runs hook checks

{ inputs, ... }:

{
  imports = [
    inputs.git-hooks.flakeModule
  ];

  perSystem =
    { pkgs, config, ... }:
    {
      pre-commit = {
        check.enable = true;

        settings = {
          # Exclude generated and external directories
          excludes = [
            "^vendor/"
            "^vendor-combined/"
            "^result.*/"
            "^redox-src/"
          ];

          hooks = {
            # Nix formatting
            nixfmt-rfc-style = {
              enable = true;
              package = pkgs.nixfmt-rfc-style;
            };

            # Prevent merge conflict markers
            check-merge-conflicts.enable = true;

            # Prevent large files
            check-added-large-files = {
              enable = true;
              # Allow up to 1MB (disk images are in result/)
              stages = [ "pre-commit" ];
            };

            # Whitespace cleanup
            trim-trailing-whitespace = {
              enable = true;
              stages = [ "pre-commit" ];
            };

            # Ensure newline at end of file
            end-of-file-fixer = {
              enable = true;
              stages = [ "pre-commit" ];
            };

            # Check TOML syntax
            check-toml.enable = true;

            # Check JSON syntax
            check-json.enable = true;
          };
        };
      };

      # Expose the shell hook for devShells
      _module.args.gitHooksShellHook = config.pre-commit.installationScript;
    };
}
