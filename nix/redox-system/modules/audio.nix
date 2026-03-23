# Audio Configuration (/audio)
#
# Controls the audiod daemon independently of the graphics subsystem.
# Audio hardware drivers (ihdad, ac97d, sb16d) are managed by /hardware.audioEnable.
# This module controls the userspace audio daemon.

adios:

let
  t = adios.types;
  serviceType = import ../lib/service-type.nix { inherit t; };
in

{
  name = "audio";

  inputs = {
    hardware = {
      path = "/hardware";
    };
  };

  options = {
    enable = {
      type = t.bool;
      default = false;
      description = "Enable the audio daemon (audiod). Requires hardware.audioEnable = true for audio drivers.";
    };
    services = {
      type = t.attrsOf serviceType;
      description = "Audio services (computed from module options)";
      defaultFunc =
        { options, inputs, ... }:
        if !options.enable then
          { }
        else
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
          };
    };
  };

  impl = { options }: options;
}
