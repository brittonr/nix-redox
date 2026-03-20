# Graphics Configuration (/graphics)
#
# Orbital desktop environment settings.
# The /build module uses these to conditionally include graphics daemons,
# packages, init scripts, and environment variables.

adios:

let
  t = adios.types;
  serviceType = import ../lib/service-type.nix { inherit t; };
in

{
  name = "graphics";

  inputs = {
    hardware = {
      path = "/hardware";
    };
    pkgs = {
      path = "/pkgs";
    };
  };

  options = {
    enable = {
      type = adios.types.bool;
      default = false;
      description = "Enable Orbital graphical desktop";
    };

    resolution = {
      type = adios.types.string;
      default = "1024x768";
      description = "Display resolution (WIDTHxHEIGHT)";
    };

    virtualTerminal = {
      type = adios.types.int;
      default = 3;
      description = "Virtual terminal number for Orbital (VT=1 conflicts with inputd, VT=2 with fbcond)";
    };

    display = {
      type = adios.types.string;
      default = ":0";
      description = "DISPLAY environment variable value";
    };
    loginCommand = {
      type = adios.types.string;
      default = "";
      description = "Command for Orbital to launch after startup (e.g. \"orblogin orbterm\"). Empty string auto-detects: uses orblogin+orbterm when orbutils is available, falls back to login.";
    };
    services = {
      type = t.attrsOf serviceType;
      description = "Graphics services (computed from module options)";
      defaultFunc =
        { options, inputs, ... }:
        if !options.enable then
          { }
        else
          let
            pkgs = inputs.pkgs.pkgs;
            loginCmd =
              if options.loginCommand != "" then
                options.loginCommand
              else if pkgs ? orbutils then
                "orblogin orbterm"
              else
                "login";
          in
          {
            orbital = {
              description = "Orbital desktop environment";
              command = "orbital";
              type = "nowait";
              args = loginCmd;
              wantedBy = "rootfs";
              enable = true;
              after = [
                "ptyd"
                "ipcd"
              ];
              environment = {
                VT = toString options.virtualTerminal;
              };
              priority = 50;
            };
          }
          // (
            if inputs.hardware.audioEnable then
              {
                audiod = {
                  description = "Audio daemon";
                  command = "audiod";
                  type = "daemon";
                  args = "";
                  wantedBy = "rootfs";
                  enable = true;
                  after = [ ];
                  environment = { };
                  priority = 50;
                };
              }
            else
              { }
          );
    };
  };

  impl = { options }: options;
}
