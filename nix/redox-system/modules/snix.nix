# snix Configuration (/snix)
#
# Declarative configuration for snix scheme daemons and build sandboxing.
#
# Options:
#   stored.enable  — run the stored daemon (lazy NAR extraction via store: scheme)
#   profiled.enable — run the profiled daemon (union profiles via profile: scheme)
#   sandbox        — enable namespace sandboxing for snix builds

adios:

let
  t = adios.types;

  storedConfig = t.struct "StoredConfig" {
    enable = t.bool;
    cachePath = t.string;
    storeDir = t.string;
  };

  profiledConfig = t.struct "ProfiledConfig" {
    enable = t.bool;
    profilesDir = t.string;
    storeDir = t.string;
  };
in

{
  name = "snix";

  options = {
    stored = {
      type = storedConfig;
      default = {
        enable = false;
        cachePath = "/nix/cache";
        storeDir = "/nix/store";
      };
      description = "Store scheme daemon configuration (lazy NAR extraction)";
    };
    profiled = {
      type = profiledConfig;
      default = {
        enable = false;
        profilesDir = "/nix/var/snix/profiles";
        storeDir = "/nix/store";
      };
      description = "Profile scheme daemon configuration (union package views)";
    };
    sandbox = {
      type = t.bool;
      default = true;
      description = "Enable namespace sandboxing for snix builds (Redox only)";
    };
  };

  impl = { options }: options;
}
