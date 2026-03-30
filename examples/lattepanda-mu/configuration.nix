# LattePanda Mu (N100) on Carrier Lite — bare metal
#
# Boots from USB flash drive or M.2 NVMe SSD.
# Drivers: NVMe, RTL8168 Ethernet, xHCI USB, vesad (UEFI GOP).
# Audio (ihdad) omitted until PCI device ID audit is done.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/time" = {
    hostname = "lattepanda-mu";
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
      ++ opt "helix";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
    };
  };

  # Text console on HDMI: route keyboard input to fbcond's VT so getty
  # receives keypresses from JetKVM USB HID (inputd → fbcond → pty → login).
  # Default inputdVT=1 routes input to VT 1 (nobody listening).
  "/console" = {
    inputdVT = 2; # Match fbcondVT (default 2) so input reaches text console
  };

  "/hardware" = {
    # Real hardware — no virtio drivers
    storageDrivers = [
      "nvmed"
      "ahcid"
    ];
    networkDrivers = [
      "rtl8168d"
      "e1000d" # fallback
    ];
    # No graphicsDrivers needed — vesad handles UEFI GOP framebuffer
    # (virtio-gpud and bgad are VM-only)
    graphicsDrivers = [ ];
    usbEnable = true;
    audioEnable = false;
    audioDrivers = [ ];
  };

  "/networking" = {
    enable = true;
    mode = "auto";
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

  # Getty on fbcond VT 2 (HDMI text console) instead of default debug: serial
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
    # ps2d crashes on N100 (no PS/2 controller, USB-only)
    # acpid: Match opcode now fully implemented — re-enabled for ACPI/PCI
    # BAR mapping which is required for USB, NVMe, and network on N100.
    initfsExcludeDaemons = [
      "ps2d"
      "usbscsid"
    ];
    # USB mass storage driver — needed for JetKVM virtual media boot
    initfsExtraDrivers = [ "usbscsid" ];
    # vesad + fbcond for text console on HDMI (no Orbital needed)
    initfsEnableGraphics = true;
  };

  "/virtualisation" = {
    memorySize = 4096;
    cpus = 4;
  };
}
