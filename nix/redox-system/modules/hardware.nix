# Hardware Configuration (/hardware)
#
# Driver selection for storage, network, graphics, audio, USB.

adios:

let
  t = adios.types;

  storageDriver = t.enum "StorageDriver" [
    "ahcid"
    "nvmed"
    "ided"
    "virtio-blkd"
    "virtio-fsd"
  ];
  networkDriver = t.enum "NetworkDriver" [
    "e1000d"
    "virtio-netd"
    "rtl8168d"
  ];
  graphicsDriver = t.enum "GraphicsDriver" [
    "virtio-gpud"
    "bgad"
  ];
  audioDriver = t.enum "AudioDriver" [
    "ihdad"
    "ac97d"
    "sb16d"
  ];
in

{
  name = "hardware";

  options = {
    storageDrivers = {
      type = t.listOf storageDriver;
      default = [
        "ahcid"
        "nvmed"
        "virtio-blkd"
      ];
      description = "Storage controller drivers";
    };
    networkDrivers = {
      type = t.listOf networkDriver;
      default = [
        "e1000d"
        "virtio-netd"
      ];
      description = "Network interface drivers";
    };
    graphicsEnable = {
      type = t.bool;
      default = false;
      description = "Enable graphics drivers";
    };
    graphicsDrivers = {
      type = t.listOf graphicsDriver;
      default = [
        "virtio-gpud"
        "bgad"
      ];
      description = "Graphics drivers";
    };
    audioEnable = {
      type = t.bool;
      default = false;
      description = "Enable audio drivers";
    };
    audioDrivers = {
      type = t.listOf audioDriver;
      default = [
        "ihdad"
        "ac97d"
        "sb16d"
      ];
      description = "Audio drivers";
    };
    usbEnable = {
      type = t.bool;
      default = false;
      description = "Enable USB support";
    };
    extraPciDrivers = {
      type = t.attrsOf (t.listOf (t.struct "PciMatch" {
        name = t.string;
        class = t.optionalAttr t.string;
        subclass = t.optionalAttr t.string;
        vendor = t.optionalAttr t.string;
        device = t.optionalAttr t.string;
      }));
      default = { };
      description = "Extra PCI driver entries merged with the built-in registry. Keys are driver binary names, values are lists of PCI match rules.";
    };
  };

  impl = { options }: options;
}
