# Boot Configuration (/boot)
#
# Kernel, bootloader, and initfs settings.

adios:

let
  t = adios.types;
in

{
  name = "boot";

  inputs = {
    pkgs = {
      path = "/pkgs";
    };
  };

  options = {
    kernel = {
      # attrs not derivation: defaultFunc may return {} when package missing
      type = t.attrs;
      defaultFunc = { inputs }: inputs.pkgs.pkgs.kernel or { };
      description = "Kernel package";
    };
    bootloader = {
      # attrs not derivation: defaultFunc may return {} when package missing
      type = t.attrs;
      defaultFunc = { inputs }: inputs.pkgs.pkgs.bootloader or { };
      description = "Bootloader package";
    };
    initfsExtraBinaries = {
      type = t.listOf t.string;
      default = [ ];
      description = "Extra binaries to include in initfs";
    };
    initfsExtraDrivers = {
      type = t.listOf t.string;
      default = [ ];
      description = "Extra drivers to include in initfs";
    };
    initfsEnableGraphics = {
      type = t.bool;
      default = false;
      description = "Enable graphics in initfs (vesad, inputd, ps2d)";
    };
    diskSizeMB = {
      type = t.int;
      default = 512;
      description = "Disk image size in megabytes";
    };
    espSizeMB = {
      type = t.int;
      default = 200;
      description = "EFI System Partition size in megabytes";
    };
  };

  impl = { options }: options;
}
