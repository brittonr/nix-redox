# Hardware Configuration (/hardware)
#
# Driver selection for storage, network, graphics, audio, USB.
# The /build module computes derived values (allDrivers, pcidDrivers, etc.)
# from these options.

adios:

{
  name = "hardware";

  options = {
    storageDrivers = {
      type = adios.types.list;
      default = [
        "ahcid"
        "nvmed"
        "virtio-blkd"
      ];
      description = "Storage controller drivers";
    };

    networkDrivers = {
      type = adios.types.list;
      default = [
        "e1000d"
        "virtio-netd"
      ];
      description = "Network interface drivers";
    };

    graphicsEnable = {
      type = adios.types.bool;
      default = false;
      description = "Enable graphics support";
    };

    graphicsDrivers = {
      type = adios.types.list;
      default = [
        "virtio-gpud"
        "bgad"
      ];
      description = "Graphics drivers (when graphics enabled)";
    };

    audioEnable = {
      type = adios.types.bool;
      default = false;
      description = "Enable audio support";
    };

    audioDrivers = {
      type = adios.types.list;
      default = [
        "ihdad"
        "ac97d"
        "sb16d"
      ];
      description = "Audio drivers (when audio enabled)";
    };

    usbEnable = {
      type = adios.types.bool;
      default = false;
      description = "Enable USB support";
    };
  };

  impl = { options }: options;
}
