# Minimal RedoxOS Profile
#
# Bare minimum: ion + uutils, no networking, no graphics.
# Usage: redoxSystem { modules = [ ./profiles/minimal.nix ]; ... }

{ pkgs, lib }:

{
  "/environment" = {
    systemPackages =
      (if pkgs ? ion then [ pkgs.ion ] else [ ]) ++ (if pkgs ? uutils then [ pkgs.uutils ] else [ ]);
  };

  "/networking" = {
    enable = false;
  };

  "/graphics" = {
    enable = false;
  };
}
