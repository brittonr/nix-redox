# Flake-free development shells (inputs pinned by Nixtamal; see default.nix).
#
#   nix-shell              # default shell
#   nix-shell -A native    # full native shell with all dependencies
#   nix-shell -A minimal   # minimal shell
{
  system ? builtins.currentSystem,
}:
let
  devShells = (import ./default.nix { inherit system; }).devShells.${system};
in
devShells.default // { inherit (devShells) native minimal; }
