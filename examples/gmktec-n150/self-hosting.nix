# GMKtec N150 — self-hosting bare metal
#
# Intel N150 (Alder Lake-N), 16GB RAM, 512GB NVMe, Intel I226-V 2.5GbE.
# Full Rust toolchain: rustc, cargo, LLVM, relibc sysroot.
# Boots via JetKVM virtual media (UEFI USB), runs from RAM (liveMode).
#
# 4GB image in 16GB RAM → ~12GB free for compilation.

{ pkgs, lib }:

let
  # Layer: development profile → self-hosting additions → N150 hardware overrides
  dev = import ../../nix/redox-system/profiles/development.nix { inherit pkgs lib; };
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/time" = {
    hostname = "gmk1";
    timezone = "America/New_York";
  };

  "/environment" = {
    systemPackages =
      # Development profile packages (editors, CLI tools, build tools)
      (dev."/environment".systemPackages or [ ])
      # Rust toolchain
      ++ opt "redox-rustc"
      ++ opt "redox-libstdcxx-shim"
      # Minimal LLVM (clang, lld, llvm-ar)
      ++ opt "redox-llvm"
      # relibc sysroot (headers + static libs)
      ++ opt "redox-sysroot"
      # cmake for C/C++ projects
      ++ opt "redox-cmake"
      # Stack-growing lld launcher (JOBS>=2 fix)
      ++ opt "lld-wrapper"
      # Networking
      ++ opt "redox-curl";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
    };

    variables = {
      REDOX_SYSROOT = "/usr/lib/redox-sysroot/sysroot";
      CARGO_BUILD_JOBS = "4";
    };
  };

  # Text console on HDMI via fbcond
  "/console" = {
    inputdVT = 2;
  };

  "/hardware" = {
    storageDrivers = [
      "nvmed"
      "ahcid"
    ];
    # Intel I226-V [8086:125c]
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
    remoteShellEnable = true;
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

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
      "bin/dash" = "/bin/ion";
      "bin/vi" = "/bin/sodium";
    };
  };

  "/services" = {
    getty = {
      enable = "true";
      device = "2";
      extraArgs = "-J";
    };
  };

  "/boot" = {
    # 2.5GB: 1.6GB actual data + RedoxFS overhead + working space
    # UEFI liveMode must fit in contiguous EFI memory (4GB fails on N150)
    diskSizeMB = 2560;
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
    memorySize = 8192;
    cpus = 4;
  };
}
