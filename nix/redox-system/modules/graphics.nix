# Graphics Configuration (/graphics)
#
# Orbital desktop environment settings.
# The /build module uses these to conditionally include graphics daemons,
# packages, init scripts, and environment variables.

adios:

{
  name = "graphics";

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
  };

  impl = { options }: options;
}
