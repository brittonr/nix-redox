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
  serviceType = import ../lib/service-type.nix { inherit t; };

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
    services = {
      type = t.attrsOf serviceType;
      description = "Snix services (computed from module options)";
      defaultFunc =
        { options, ... }:
        (
          if options.stored.enable then
            {
              stored = {
                description = "snix store scheme daemon (lazy NAR extraction)";
                command = "/bin/stored";
                type = "daemon";
                args = "--cache-path ${options.stored.cachePath} --store-dir ${options.stored.storeDir}";
                wantedBy = "rootfs";
                enable = true;
                after = [ "ptyd" ];
                environment = { };
                priority = 12;
              };
            }
          else
            { }
        )
        // (
          if options.profiled.enable then
            {
              profiled = {
                description = "snix profile scheme daemon (union package views)";
                command = "/bin/snix";
                type = "nowait";
                args = "profiled --profiles-dir ${options.profiled.profilesDir} --store-dir ${options.profiled.storeDir}";
                wantedBy = "rootfs";
                enable = true;
                after = [ "stored" ];
                environment = { };
                priority = 13;
              };
            }
          else
            { }
        );
    };
  };

  impl = { options }: options;
}
