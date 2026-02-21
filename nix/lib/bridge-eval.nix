# bridge-eval.nix — Translate guest RebuildConfig → adios module overrides → rootTree
#
# Called by the build-bridge daemon when a guest sends a rebuild request.
# The config JSON uses the RebuildConfig schema (flat keys like "hostname",
# "packages", "networking.mode") and this expression translates them into
# the adios module system's path-keyed override format.
#
# Usage (called by the daemon):
#   nix build --file bridge-eval.nix --impure \
#     --arg flakeDir '"/path/to/flake"' \
#     --arg configPath '"/path/to/request-config.json"' \
#     --arg profile '"default"'
#
# The config JSON is the "config" field from the bridge request, e.g.:
#   { "hostname": "my-redox", "packages": ["ripgrep", "fd"],
#     "networking": { "mode": "dhcp" } }

{
  flakeDir,
  configPath,
  profile ? "default",
}:

let
  flake = builtins.getFlake flakeDir;
  system = builtins.currentSystem;
  lp = flake.legacyPackages.${system};

  config = builtins.fromJSON (builtins.readFile configPath);

  # Get the package set from the existing system configuration.
  # This is the flat namespace of all cross-compiled Redox packages.
  systemPkgs = lp.redoxConfigurations.${profile}._module.pkgs;

  # Resolve a package name to a derivation.
  # Tries direct name first, then common aliases.
  resolvePackage =
    name:
    if systemPkgs ? ${name} then
      systemPkgs.${name}
    else if name == "ion" && systemPkgs ? ion-shell then
      systemPkgs.ion-shell
    else if name == "base" && systemPkgs ? redox-base then
      systemPkgs.redox-base
    else if name == "snix" && systemPkgs ? snix-redox then
      systemPkgs.snix-redox
    else
      builtins.throw "unknown package: ${name} (available: ${builtins.concatStringsSep ", " (builtins.attrNames systemPkgs)})";

  # === Build module overrides from config fields ===

  # Environment: packages
  envOverride =
    if config ? packages && builtins.isList config.packages then
      {
        "/environment" = {
          systemPackages = map resolvePackage config.packages;
        };
      }
    else
      { };

  # Time: hostname, timezone
  timeFields =
    { }
    // (if config ? hostname then { hostname = config.hostname; } else { })
    // (if config ? timezone then { timezone = config.timezone; } else { });
  timeOverride = if timeFields != { } then { "/time" = timeFields; } else { };

  # Networking
  netOverride = if config ? networking then { "/networking" = config.networking; } else { };

  # Graphics
  gfxOverride = if config ? graphics then { "/graphics" = config.graphics; } else { };

  # Security
  secOverride = if config ? security then { "/security" = config.security; } else { };

  # Logging
  logOverride = if config ? logging then { "/logging" = config.logging; } else { };

  # Power
  pwrOverride = if config ? power then { "/power" = config.power; } else { };

  # Users
  usrOverride =
    if config ? users then
      {
        "/users" = {
          users = config.users;
        };
      }
    else
      { };

  # Programs
  prgOverride = if config ? programs then { "/programs" = config.programs; } else { };

  # Merge all overrides into a single module attrset
  overrides =
    envOverride
    // timeOverride
    // netOverride
    // gfxOverride
    // secOverride
    // logOverride
    // pwrOverride
    // usrOverride
    // prgOverride;

  # Build the new system by extending the base profile with overrides
  newSystem = lp.redoxConfigurations.${profile}.extend overrides;

in
newSystem.rootTree
