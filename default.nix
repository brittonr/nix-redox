# Flake-free entry point: the flake's outputs, with inputs pinned by Nixtamal
# (nix/tamal) instead of fetched through flakes. See docs/nixtamal.md.
#
#   nix-build                                     # packages.<system>.default
#   nix-build -A packages.x86_64-linux.diskImage
#   nix-build -A checks.x86_64-linux.tier-eval
{
  system ? builtins.currentSystem,
}:
let
  flake = import ./nix/nixtamal.nix;
in
flake // { default = flake.packages.${system}.default; }
