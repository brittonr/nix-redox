# Scheme-Native RedoxOS Profile
#
# Extends the development profile with Redox scheme daemons enabled:
# - stored: lazy NAR extraction via store: scheme
# - profiled: union package views via profile: scheme
# - sandbox: namespace sandboxing for snix builds
#
# Usage: redoxSystem { profiles = [ "scheme-native" ]; ... }

{ pkgs, lib }:

let
  dev = import ./development.nix { inherit pkgs lib; };
in
dev
// {
  "/snix" = {
    stored = {
      enable = true;
      cachePath = "/nix/cache";
      storeDir = "/nix/store";
    };
    profiled = {
      enable = true;
      profilesDir = "/nix/var/snix/profiles";
      storeDir = "/nix/store";
    };
    sandbox = true;
  };
}
