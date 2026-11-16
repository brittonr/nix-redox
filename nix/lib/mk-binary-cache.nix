# mk-binary-cache.nix — Generate a Nix-compatible binary cache from packages
#
# Takes a set of packages and produces a directory with:
#   nix-cache-info          — cache metadata
#   packages.json           — v2 installable-root index for `snix install`
#   {hash}.narinfo          — per-path metadata
#   nar/{sha256}.nar.zst    — compressed NAR files
#   closure.json            — v1 complete direct-reference graph and evidence
#   transport.json          — v1 per-root SHA256/size-pinned file inventory
#
# Usage:
#   mkBinaryCache = import ./mk-binary-cache.nix { inherit hostPkgs lib; };
#   cache = mkBinaryCache {
#     packages = { ripgrep = ripgrep-drv; fd = fd-drv; };
#   };

{ hostPkgs, lib }:

{
  packages, # attrset of { name = derivation; ... }; only these are advertised
  target ? "x86_64-unknown-redox",
  # Dependency records keep path context in values, not attribute names:
  # [ { path = "${dependency}"; target = target; evidence = "..."; } ]
  pathMetadata ? [ ],
}:

let
  # TARGET/CARGO_BUILD_TARGET describe the produced artifact, unlike `system`
  # (the builder platform). Never infer a target from a package's name.
  declaredTarget =
    drv:
    if drv ? TARGET then
      {
        target = drv.TARGET;
        evidence = "derivation.TARGET";
      }
    else if drv ? CARGO_BUILD_TARGET then
      {
        target = drv.CARGO_BUILD_TARGET;
        evidence = "derivation.CARGO_BUILD_TARGET";
      }
    else if drv ? stdenv && drv.stdenv ? hostPlatform then
      {
        target = drv.stdenv.hostPlatform.config;
        evidence = "derivation.stdenv.hostPlatform.config";
      }
    else
      null;
  packageEntries = lib.mapAttrsToList (name: drv: {
    inherit name;
    # Interpolation and exportReferencesGraph both preserve output context.
    storePath = "${drv}";
    pname = drv.pname or name;
    version = drv.version or "unknown";
    compatibility = declaredTarget drv;
  }) packages;
in
hostPkgs.runCommand "redox-binary-cache"
  {
    __structuredAttrs = true;
    inherit packageEntries pathMetadata target;
    exportReferencesGraph.closure = map (entry: entry.storePath) packageEntries;
    nativeBuildInputs = [
      hostPkgs.python3
      hostPkgs.zstd
    ];
    # Nix adds the full runtime graph (including direct references) to attrs
    # JSON and makes every member available in the builder's sandbox.
  }
  ''
    echo "Building binary cache for ${toString (builtins.length packageEntries)} packages..."
    python3 ${./build-binary-cache.py} \
      "$NIX_ATTRS_JSON_FILE" \
      "$out"
  ''
