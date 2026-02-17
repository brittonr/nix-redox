# Minimal RedoxOS Profile
#
# A bare-minimum system with just Ion shell and basic utilities.
# No networking, no graphics, no developer tools.
#
# Usage:
#   redoxSystem { modules = [ ./profiles/minimal.nix ]; }

{
  config,
  lib,
  pkgs,
  ...
}:

{
  redox.environment.systemPackages =
    lib.optional (pkgs ? ion) pkgs.ion ++ lib.optional (pkgs ? uutils) pkgs.uutils;

  redox.networking.enable = lib.mkDefault false;
  redox.graphics.enable = lib.mkDefault false;
}
