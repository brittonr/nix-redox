# GMKtec N150 — bare metal
#
# Intel N150 (Alder Lake-N), 16GB RAM, 512GB NVMe.
# Drivers: NVMe, Realtek RTL8168 Ethernet, xHCI USB, vesad (UEFI GOP).
# Based on LattePanda Mu (N100) config — same SoC family.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/time" = {
    hostname = "gmk1";
    timezone = "America/New_York";
  };

  "/environment" = {
    systemPackages =
      # Shell & coreutils
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "userutils"
      # Editors
      ++ opt "helix"
      # CLI tools
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      # Networking
      ++ opt "netutils"
      ++ opt "redox-curl"
      # System management
      ++ opt "snix";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
    };
  };

  # Text console on HDMI: route keyboard input to fbcond's VT so getty
  # receives keypresses from JetKVM USB HID (inputd → fbcond → pty → login).
  "/console" = {
    inputdVT = 2; # Match fbcondVT (default 2) so input reaches text console
  };

  "/hardware" = {
    # Real hardware — no virtio drivers
    storageDrivers = [
      "nvmed"
      "ahcid"
    ];
    # Intel I226-V [8086:125c] — igc family (I225/I226 2.5GbE)
    networkDrivers = [
      "igcd"
    ];
    # vesad handles UEFI GOP framebuffer — no extra graphics drivers
    graphicsDrivers = [ ];
    usbEnable = true;
    audioEnable = false;
    audioDrivers = [ ];
  };

  "/networking" = {
    enable = true;
    mode = "static";
    interfaces.eth0 = {
      address = "192.168.1.146/24";
      gateway = "192.168.1.1";
    };
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };

  "/users".users = {
    root = {
      uid = 0;
      gid = 0;
      home = "/root";
      shell = "/bin/ion";
      password = "redox";
      realname = "root";
      createHome = true;
    };
    user = {
      uid = 1000;
      gid = 1000;
      home = "/home/user";
      shell = "/bin/ion";
      password = "redox";
      realname = "User";
      createHome = true;
    };
  };

  "/programs" = {
    helix = {
      enable = true;
      theme = "default";
    };
    editor = "/bin/hx";
  };

  # Getty on fbcond VT 2 (HDMI text console)
  "/services" = {
    getty = {
      enable = "true";
      device = "2"; # Maps to /scheme/fbcon/2 (fbcond VT)
      extraArgs = "-J";
    };
  };

  "/boot" = {
    diskSizeMB = 1024;
    initfsSizeMB = 128;
    liveMode = true;
    initDebug = true;
    # ps2d crashes on N150 (no PS/2 controller, USB-only)
    initfsExcludeDaemons = [
      "ps2d"
      "usbscsid"
    ];
    # USB mass storage driver — needed for JetKVM virtual media boot
    initfsExtraDrivers = [ "usbscsid" ];
    # vesad + fbcond for text console on HDMI
    initfsEnableGraphics = true;
    # acpid required for ACPI/PCI BAR mapping (USB, NVMe, network).
    # AML interpreter errors on phantom _SB_.PC00.TXHC but continues.
    # N150 ACPI workaround: hwd.probe() deadlocks reading
    # /scheme/acpi/symbols after AML init fails on phantom TXHC.
    # Replace hwd with direct acpid+pcid launch (skip probe).
    initfsScripts = {
      "40_hwd.service" = ''
        [unit]
        description = "ACPI + PCI daemons (skip hwd probe — N150 AML bug)"
        requires_weak = ["30_lived.service"]

        [service]
        cmd = "acpid"
        inherit_envs = ["RSDP_ADDR", "RSDP_SIZE"]
        type = "notify"
      '';
      "40_pcid.service" = ''
        [unit]
        description = "PCI daemon"
        requires_weak = ["40_hwd.service"]

        [service]
        cmd = "pcid"
        type = "notify"
      '';
      "40_pcid-spawner.service" = ''
        [unit]
        description = "PCI driver spawner"
        requires_weak = ["30_lived.service", "40_hwd.service", "40_pcid.service"]

        [service]
        cmd = "pcid-spawner"
        args = ["--initfs"]
        type = "oneshot"
      '';
    };
  };

  "/virtualisation" = {
    memorySize = 4096;
    cpus = 4;
  };
}
