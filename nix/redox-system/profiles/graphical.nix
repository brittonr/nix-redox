# Graphical RedoxOS Profile
#
# Orbital desktop + audio, built on development profile.
# Usage: redoxSystem { modules = [ ./profiles/graphical.nix ]; ... }

{ pkgs, lib }:

let
  dev = import ./development.nix { inherit pkgs lib; };
in
dev
// {
  "/graphics" = (dev."/graphics" or { }) // {
    enable = true;
  };

  "/hardware" = (dev."/hardware" or { }) // {
    audioEnable = true;
  };
}
