# bridge-eval.nix — Translate guest RebuildConfig → adios module overrides → rootTree
#
# Called by the build-bridge daemon when a guest sends a rebuild request.
# The config JSON uses the RebuildConfig schema (flat keys like "hostname",
# "packages", "networking.mode") and this expression translates them into
# the adios module system's path-keyed override format.
#
# IMPORTANT: adios .extend uses `//` at module path level, so an override for
# "/environment" REPLACES the entire /environment block from the profile.
# We must resolve the profile's existing module options and merge them with
# the config override to preserve boot-essential packages, aliases, etc.
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
  lib = lp.redoxConfigurations.${profile}._module.hostPkgs.lib;

  config = builtins.fromJSON (builtins.readFile configPath);

  # Access the base profile's configuration.
  baseSys = lp.redoxConfigurations.${profile};

  # Get the package set from the existing system configuration.
  # This is the flat namespace of all cross-compiled Redox packages.
  systemPkgs = baseSys._module.pkgs;

  # Resolve the profile's module definitions to get existing options.
  # Each module is a path/function/attrset that returns { "/path" = { options... }; }.
  # We need these to merge with (not replace) the bridge config overrides.
  profileOptions = builtins.foldl' (
    acc: mod:
    let
      resolved =
        if builtins.isPath mod || builtins.isString mod then
          import mod {
            pkgs = systemPkgs;
            inherit lib;
          }
        else if builtins.isFunction mod then
          mod {
            pkgs = systemPkgs;
            inherit lib;
          }
        else
          mod;
    in
    acc // resolved
  ) { } baseSys._module.modules;

  # Resolve a package name to a derivation.
  # Direct attribute lookup — no aliases needed because the pkgs attrset
  # already uses the canonical short names (ion, base, snix, etc.).
  resolvePackage =
    name:
    if systemPkgs ? ${name} then
      systemPkgs.${name}
    else
      builtins.throw "unknown package: ${name} (available: ${builtins.concatStringsSep ", " (builtins.attrNames systemPkgs)})";

  # === Build module overrides from config fields ===
  #
  # Each override must include the FULL module path options (not just changed fields)
  # because .extend uses `//` at the path level, which replaces the entire attrset.
  #
  # IMPORTANT: serde serializes Option<T>::None as JSON null. In Nix, `{ x = null; } ? x`
  # returns true, so we must check BOTH presence AND non-null with `hasNonNull`.
  hasNonNull = field: config ? ${field} && config.${field} != null;

  # Environment: merge packages additively with the profile's existing packages.
  # The config's "packages" field adds to (not replaces) the profile's systemPackages.
  existingEnv = profileOptions."/environment" or { };
  existingPkgs = existingEnv.systemPackages or [ ];

  envOverride =
    if hasNonNull "packages" && builtins.isList config.packages then
      let
        requestedPkgs = map resolvePackage config.packages;
        # Combine: existing profile packages + requested (dedup by derivation identity)
        combinedPkgs =
          existingPkgs ++ (builtins.filter (rp: !(builtins.any (ep: ep == rp) existingPkgs)) requestedPkgs);
      in
      {
        "/environment" = existingEnv // {
          systemPackages = combinedPkgs;
        };
      }
    else
      { };

  # Time: hostname, timezone — merge with existing profile /time options
  existingTime = profileOptions."/time" or { };
  timeFields =
    existingTime
    // (if hasNonNull "hostname" then { hostname = config.hostname; } else { })
    // (if hasNonNull "timezone" then { timezone = config.timezone; } else { });
  timeOverride = if timeFields != existingTime then { "/time" = timeFields; } else { };

  # Networking: merge with existing profile /networking options
  existingNet = profileOptions."/networking" or { };
  netOverride =
    if hasNonNull "networking" then { "/networking" = existingNet // config.networking; } else { };

  # Graphics: merge with existing profile /graphics options
  existingGfx = profileOptions."/graphics" or { };
  gfxOverride =
    if hasNonNull "graphics" then { "/graphics" = existingGfx // config.graphics; } else { };

  # Security: merge with existing profile /security options
  existingSec = profileOptions."/security" or { };
  secOverride =
    if hasNonNull "security" then { "/security" = existingSec // config.security; } else { };

  # Logging: merge with existing profile /logging options
  existingLog = profileOptions."/logging" or { };
  logOverride = if hasNonNull "logging" then { "/logging" = existingLog // config.logging; } else { };

  # Power: merge with existing profile /power options
  existingPwr = profileOptions."/power" or { };
  pwrOverride = if hasNonNull "power" then { "/power" = existingPwr // config.power; } else { };

  # Users: merge with existing profile /users options
  existingUsr = profileOptions."/users" or { };
  usrOverride =
    if hasNonNull "users" then
      {
        "/users" = existingUsr // {
          users = config.users;
        };
      }
    else
      { };

  # Programs: merge with existing profile /programs options
  existingPrg = profileOptions."/programs" or { };
  prgOverride =
    if hasNonNull "programs" then { "/programs" = existingPrg // config.programs; } else { };

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
  newSystem = baseSys.extend overrides;

in
newSystem.rootTree
