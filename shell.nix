# Backwards-compatible shell.nix that delegates to the flake
#
# This is a thin wrapper around the flake's devShells.
# Prefer using `nix develop` directly with flakes.
#
# Usage:
#   nix-shell              # default shell
#   nix-shell -A native    # full native shell with all dependencies
#   nix-shell -A minimal   # minimal shell
#
# Or with flakes (recommended):
#   nix develop            # default shell
#   nix develop .#native   # full native shell
#   nix develop .#minimal  # minimal shell

let
  flake = builtins.getFlake (toString ./.);
  system = builtins.currentSystem;
  devShells = flake.devShells.${system};
in
devShells.default // {
  native = devShells.native;
  minimal = devShells.minimal;
}
