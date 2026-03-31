# GMKtec NucBoxG3 Plus (Intel N150) — bare metal profile
#
# Alder Lake-N, 16GB RAM, NVMe, Intel I226-V 2.5GbE.
# Boots via JetKVM virtual media (UEFI USB).
#
# N150 ACPI workaround: hwd.probe() deadlocks after AML init fails
# on phantom _SB_.PC00.TXHC. Replace hwd with direct acpid+pcid launch.

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
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "userutils"
      ++ opt "helix"
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      ++ opt "netutils"
      ++ opt "redox-curl"
      ++ opt "snix";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
    };
  };

  "/console" = {
    inputdVT = 2;
  };

  "/hardware" = {
    storageDrivers = [
      "nvmed"
      "ahcid"
    ];
    # Intel I226-V [8086:125c] — igc family (I225/I226 2.5GbE)
    networkDrivers = [
      "igcd"
    ];
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

  "/services" = {
    getty = {
      enable = "true";
      device = "2";
      extraArgs = "-J";
    };
  };

  "/boot" = {
    diskSizeMB = 1024;
    initfsSizeMB = 128;
    liveMode = true;
    initDebug = true;
    autoLogin = "root";
    initfsExcludeDaemons = [
      "ps2d"
      "usbscsid"
    ];
    initfsExtraDrivers = [ "usbscsid" ];
    initfsEnableGraphics = true;
    # N150 ACPI workaround: skip hwd.probe() which deadlocks
    initfsScripts = {
      "40_hwd.service" = ''
        [unit]
        description = "ACPI + PCI daemons (skip hwd probe)"
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
