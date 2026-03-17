# Minimal Redox OS — bare-bones headless system
#
# Just a shell, coreutils, and serial console. No graphics, no network,
# no users. Good for testing kernel/driver changes or as a starting
# point for appliance-style images.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/time".hostname = "minimal";

  "/environment" = {
    systemPackages = opt "ion" ++ opt "uutils" ++ opt "extrautils";
  };

  "/graphics".enable = false;
  "/networking".enable = false;
  "/hardware".audioEnable = false;

  "/boot" = {
    diskSizeMB = 512;
    initfsSizeMB = 64;
  };

  "/virtualisation" = {
    memorySize = 512;
    cpus = 1;
  };
}
