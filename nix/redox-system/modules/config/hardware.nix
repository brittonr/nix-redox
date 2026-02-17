# RedoxOS Hardware Configuration
#
# Manages hardware driver selection:
#   - Storage drivers (AHCI, IDE, NVMe, VirtIO-blk)
#   - Network drivers (E1000, VirtIO-net)
#   - Graphics drivers (VirtIO-gpu, BGA)
#   - Audio drivers (Intel HDA, AC97, SoundBlaster 16)
#   - USB support
#
# Provides computed options:
#   - _allDrivers: All enabled driver binaries (used by initfs)
#   - _initfsDaemons: Additional daemons needed for hardware (vesad, inputd, etc.)
#
# These are consumed by:
#   - build/initfs.nix: Includes drivers in initfs
#   - build/pcid.nix: Generates PCI driver configuration

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
    mkDefault
    types
    concatLists
    unique
    ;

  cfg = config.redox.hardware;

  # Storage driver options
  storageDrivers = [
    "ahcid" # AHCI (SATA) controller
    "ided" # IDE controller (legacy)
    "nvmed" # NVMe controller
    "virtio-blkd" # VirtIO block device (VM)
  ];

  # Network driver options
  networkDrivers = [
    "e1000d" # Intel E1000 network card
    "virtio-netd" # VirtIO network device (VM)
  ];

  # Graphics driver options
  graphicsDrivers = [
    "virtio-gpud" # VirtIO GPU (VM)
    "bgad" # BGA (Bochs Graphics Adapter)
  ];

  # Audio driver options
  audioDrivers = [
    "ihdad" # Intel High Definition Audio
    "ac97d" # AC97 audio
    "sb16d" # SoundBlaster 16
  ];

  # Compute all enabled drivers
  allDrivers = concatLists [
    cfg.storage.drivers
    cfg.network.drivers
    (lib.optionals cfg.graphics.enable cfg.graphics.drivers)
    (lib.optionals cfg.audio.enable cfg.audio.drivers)
  ];

  # Compute additional daemons needed based on hardware config
  # These aren't drivers but support services
  initfsDaemons =
    (lib.optionals cfg.graphics.enable [
      "vesad" # VESA framebuffer daemon
      "inputd" # Input device daemon
    ])
    ++ (lib.optionals cfg.usb.enable [
      "usbd" # USB host controller daemon
      "usbhid" # USB HID (keyboard/mouse) daemon
    ]);

in
{
  options.redox.hardware = {
    storage = {
      drivers = mkOption {
        type = types.listOf (types.enum storageDrivers);
        default = [
          "ahcid"
          "nvmed"
          "virtio-blkd"
        ];
        description = ''
          Storage controller drivers to include.
          Common VM configurations need virtio-blkd.
          Physical hardware typically needs ahcid or nvmed.
        '';
      };
    };

    network = {
      drivers = mkOption {
        type = types.listOf (types.enum networkDrivers);
        default = [
          "e1000d"
          "virtio-netd"
        ];
        description = ''
          Network interface drivers to include.
          VMs typically use e1000d or virtio-netd.
        '';
      };
    };

    graphics = {
      enable = mkEnableOption "graphics support" // {
        default = false;
      };

      drivers = mkOption {
        type = types.listOf (types.enum graphicsDrivers);
        default = [
          "virtio-gpud"
          "bgad"
        ];
        description = ''
          Graphics drivers to include when graphics is enabled.
          VMs typically use virtio-gpud or bgad (Bochs).
        '';
      };
    };

    audio = {
      enable = mkEnableOption "audio support" // {
        default = false;
      };

      drivers = mkOption {
        type = types.listOf (types.enum audioDrivers);
        default = [
          "ihdad"
          "ac97d"
          "sb16d"
        ];
        description = ''
          Audio drivers to include when audio is enabled.
          Common VM setups use ac97d or ihdad.
        '';
      };
    };

    usb = {
      enable = mkEnableOption "USB support" // {
        default = false;
      };
    };

    # Internal computed options (read-only)
    _allDrivers = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      internal = true;
      description = "All enabled driver binaries (computed)";
    };

    _initfsDaemons = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      internal = true;
      description = "Additional daemons needed for hardware (computed)";
    };
  };

  config = {
    # Set computed options
    redox.hardware._allDrivers = unique allDrivers;
    redox.hardware._initfsDaemons = unique initfsDaemons;
  };
}
