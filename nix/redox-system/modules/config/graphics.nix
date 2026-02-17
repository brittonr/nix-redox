# RedoxOS Graphics and Desktop Configuration
#
# Manages the Orbital graphical desktop environment:
#   - Enables graphics hardware support
#   - Enables USB for input devices
#   - Adds Orbital packages (orbital, orbterm, orbutils, etc.)
#   - Configures display resolution
#   - Sets up Orbital init script
#
# Orbital is RedoxOS's native window manager and compositor.
# When enabled, this module automatically configures all necessary
# dependencies (graphics drivers, input support, etc.)

{
  config,
  lib,
  pkgs,
  hostPkgs,
  redoxSystemLib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optional
    optionals
    ;

  cfg = config.redox.graphics;

  # Orbital startup script (matches current disk-image.nix format)
  # Uses Redox init.d format (not bash), runs orbital with orblogin
  orbitalInitScript =
    if (pkgs ? orbutils) then
      ''
        export VT 1
        nowait /bin/orbital /bin/orblogin /bin/orbterm
      ''
    else
      ''
        export VT 1
        nowait /bin/orbital /bin/login
      '';

in
{
  options.redox.graphics = {
    enable = mkEnableOption "Orbital graphical desktop environment" // {
      default = false;
    };

    resolution = mkOption {
      type = types.str;
      default = "1024x768";
      description = ''
        Display resolution for Orbital.
        Format: WIDTHxHEIGHT
      '';
      example = "1920x1080";
    };
  };

  config = mkIf cfg.enable {
    # Enable required hardware support
    redox.hardware.graphics.enable = true;
    redox.hardware.usb.enable = true;

    # Enable graphics in initfs (needed for early framebuffer setup)
    redox.boot.initfs.enableGraphics = true;

    # Add Orbital packages to system if available
    redox.environment.systemPackages =
      optional (pkgs ? orbital) pkgs.orbital
      ++ optional (pkgs ? orbdata) pkgs.orbdata
      ++ optional (pkgs ? orbterm) pkgs.orbterm
      ++ optional (pkgs ? orbutils) pkgs.orbutils;

    # Add Orbital init script (priority 20 - after network and basic services)
    redox.services.initScripts."20_orbital" = {
      text = orbitalInitScript;
      directory = "usr/lib/init.d";
    };

    # Set environment variables for Orbital
    redox.environment.variables = {
      ORBITAL_RESOLUTION = cfg.resolution;
      DISPLAY = ":0";
    };

    # Add helpful aliases for graphics
    redox.environment.shellAliases = {
      gui = "orbital";
      term = "orbterm";
    };
  };
}
