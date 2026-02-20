# mk-binary-cache.nix — Generate a Nix-compatible binary cache from packages
#
# Takes a set of packages and produces a directory with:
#   nix-cache-info          — cache metadata
#   packages.json           — name → store path index (for `snix install`)
#   {hash}.narinfo          — per-path metadata
#   nar/{sha256}.nar.zst    — compressed NAR files
#
# Usage:
#   mkBinaryCache = import ./mk-binary-cache.nix { inherit hostPkgs lib; };
#   cache = mkBinaryCache {
#     packages = { ripgrep = ripgrep-drv; fd = fd-drv; };
#   };

{ hostPkgs, lib }:

{
  packages, # attrset of { name = derivation; ... }
}:

let
  # Build package info list with store path context preserved.
  # Using "${drv}" keeps string context so Nix tracks dependencies.
  packageEntries = lib.mapAttrsToList (name: drv: {
    inherit name;
    storePath = "${drv}";
    pname = drv.pname or name;
    version = drv.version or "unknown";
  }) packages;

  packageInfoJson = builtins.toJSON packageEntries;
in
hostPkgs.runCommand "redox-binary-cache"
  {
    nativeBuildInputs = [
      hostPkgs.python3
      hostPkgs.zstd
    ];
    passAsFile = [ "packageInfoJson" ];
    inherit packageInfoJson;
  }
  ''
    echo "Building binary cache for ${toString (builtins.length packageEntries)} packages..."
    python3 ${./build-binary-cache.py} \
      "$packageInfoJsonPath" \
      "$out"
  ''
