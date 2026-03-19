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
  };

  impl = { options }: options;
}
