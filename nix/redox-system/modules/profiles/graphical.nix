# Graphical RedoxOS Profile
#
# Full Orbital desktop environment with audio support.
# Imports development profile for CLI tools.
#
# Usage:
#   redoxSystem { modules = [ ./profiles/graphical.nix ]; }

{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./development.nix ];

  # Enable Orbital desktop
  redox.graphics.enable = true;

  # Enable audio
  redox.hardware.audio.enable = true;
}
