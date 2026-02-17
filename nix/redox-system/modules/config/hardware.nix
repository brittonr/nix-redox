# RedoxOS Hardware Configuration
#
# Manages hardware driver selection and PCI device mappings.
#
# Each driver category (storage, network, graphics, audio, USB) has:
#   - A user-facing option to select which drivers to enable
#   - PCI ID metadata for pcid (PCI daemon) configuration
#
# Provides computed options:
#   - _allDrivers: All enabled driver binaries (consumed by initfs binary copying)
#   - _initfsDaemons: Additional daemons needed for hardware (vesad, inputd, etc.)
#   - _pcidDrivers: PCI ID → driver command mappings (consumed by initfs pcid.toml)

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
    filter
    ;

  cfg = config.redox.hardware;

  # === PCI Driver Registry ===
  # Single source of truth for driver name → PCI matching criteria.
  # Each entry produces one [[drivers]] block in pcid/initfs.toml.
  # A driver may have multiple PCI entries (e.g. virtio legacy + modern).
  pciDriverRegistry = {
    # Storage
    ahcid = [
      {
        name = "AHCI (SATA)";
        class = "1";
        subclass = "6";
      }
    ];
    ided = [
      {
        name = "IDE";
        class = "1";
        subclass = "1";
      }
    ];
    nvmed = [
      {
        name = "NVMe";
        class = "1";
        subclass = "8";
      }
    ];
    virtio-blkd = [
      {
        name = "VirtIO Block Legacy";
        vendor = "0x1AF4";
        device = "0x1001";
      }
      {
        name = "VirtIO Block Modern";
        vendor = "0x1AF4";
        device = "0x1042";
      }
    ];

    # Network
    e1000d = [
      {
        name = "Intel E1000";
        class = "0x02";
        vendor = "0x8086";
        device = "0x100e";
      }
    ];
    virtio-netd = [
      {
        name = "VirtIO Net Legacy";
        class = "0x02";
        vendor = "0x1AF4";
        device = "0x1000";
      }
      {
        name = "VirtIO Net Modern";
        class = "0x02";
        vendor = "0x1AF4";
        device = "0x1041";
      }
    ];

    # Graphics
    virtio-gpud = [
      {
        name = "VirtIO GPU";
        class = "0x03";
        vendor = "0x1AF4";
        device = "0x1050";
      }
    ];
    bgad = [
      {
        name = "Bochs VGA";
        class = "0x03";
        vendor = "0x1234";
        device = "0x1111";
      }
    ];

    # Audio
    ihdad = [
      {
        name = "Intel HD Audio ICH6";
        class = "0x04";
        subclass = "0x03";
        vendor = "0x8086";
        device = "0x2668";
      }
      {
        name = "Intel HD Audio ICH9";
        class = "0x04";
        subclass = "0x03";
        vendor = "0x8086";
        device = "0x293e";
      }
    ];
    ac97d = [
      {
        name = "AC97 Audio";
        class = "0x04";
        subclass = "0x01";
        vendor = "0x8086";
        device = "0x2415";
      }
    ];
    # sb16d uses ISA, not PCI — no PCI entry needed

    # USB
    xhcid = [
      {
        name = "USB xHCI";
        class = "0x0C";
        subclass = "0x03";
      }
    ];
  };

  # All driver option values
  storageDriverOpts = [
    "ahcid"
    "ided"
    "nvmed"
    "virtio-blkd"
  ];
  networkDriverOpts = [
    "e1000d"
    "virtio-netd"
  ];
  graphicsDriverOpts = [
    "virtio-gpud"
    "bgad"
  ];
  audioDriverOpts = [
    "ihdad"
    "ac97d"
    "sb16d"
  ];

  # Compute all enabled drivers
  allDrivers = concatLists [
    cfg.storage.drivers
    cfg.network.drivers
    (lib.optionals cfg.graphics.enable cfg.graphics.drivers)
    (lib.optionals cfg.audio.enable cfg.audio.drivers)
    (lib.optionals cfg.usb.enable [ "xhcid" ])
  ];

  # Compute PCI driver entries for enabled drivers only
  # Each entry gets `command` attached — the driver binary name
  pcidDrivers = concatLists (
    map (drv: map (entry: entry // { command = drv; }) (pciDriverRegistry.${drv} or [ ])) (
      unique allDrivers
    )
  );

  # Compute additional daemons needed based on hardware config
  initfsDaemons =
    (lib.optionals cfg.graphics.enable [
      "vesad"
      "inputd"
      "fbbootlogd"
      "fbcond"
    ])
    ++ (lib.optionals cfg.usb.enable [
      "xhcid"
      "usbhubd"
      "usbhidd"
    ]);

in
{
  options.redox.hardware = {
    storage = {
      drivers = mkOption {
        type = types.listOf (types.enum storageDriverOpts);
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
        type = types.listOf (types.enum networkDriverOpts);
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
        type = types.listOf (types.enum graphicsDriverOpts);
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
        type = types.listOf (types.enum audioDriverOpts);
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

    # Internal computed options (read-only, consumed by build modules)
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

    _pcidDrivers = mkOption {
      type = types.listOf types.attrs;
      readOnly = true;
      internal = true;
      description = "PCI ID → driver command mappings for pcid.toml (computed)";
    };
  };

  config = {
    redox.hardware._allDrivers = unique allDrivers;
    redox.hardware._initfsDaemons = unique initfsDaemons;
    redox.hardware._pcidDrivers = pcidDrivers;
  };
}
