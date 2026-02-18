# Boot Configuration (/boot)
#
# Kernel, bootloader, and initfs configuration.
# Options are consumed by the /build module.

adios:

{
  name = "boot";

  inputs = {
    pkgs = {
      path = "/pkgs";
    };
  };

  options = {
    kernel = {
      type = adios.types.attrs;
      defaultFunc = { inputs }: inputs.pkgs.pkgs.kernel or { };
      description = "Kernel package";
    };

    bootloader = {
      type = adios.types.attrs;
      defaultFunc = { inputs }: inputs.pkgs.pkgs.bootloader or { };
      description = "UEFI bootloader package";
    };

    initfsExtraBinaries = {
      type = adios.types.list;
      default = [ ];
      description = "Extra binaries from base to include in initfs";
    };

    initfsExtraDrivers = {
      type = adios.types.list;
      default = [ ];
      description = "Extra driver binaries to include in initfs";
    };

    initfsEnableGraphics = {
      type = adios.types.bool;
      default = false;
      description = "Include graphics daemons in initfs";
    };
  };

  impl = { options }: options;
}
