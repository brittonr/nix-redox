# NixOS module: programs.redox + services.redox-vm
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.redox;
  vmCfg = config.services.redox-vm;
  system = pkgs.system;
  redoxPkgs = self.packages.${system};
in
{
  options.programs.redox = {
    enable = lib.mkEnableOption "Redox OS development tools";
  };

  options.services.redox-vm = {
    enable = lib.mkEnableOption "Redox OS virtual machine";

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start Redox VM automatically on boot";
    };

    profile = lib.mkOption {
      type = lib.types.enum [
        "default"
        "minimal"
        "graphical"
        "cloud"
      ];
      default = "default";
      description = "Redox system profile to use";
    };

    vmm = lib.mkOption {
      type = lib.types.enum [
        "cloud-hypervisor"
        "qemu"
      ];
      default = "cloud-hypervisor";
      description = "Virtual machine monitor backend";
    };

    memory = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "VM memory in megabytes";
    };

    cpus = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of virtual CPUs";
    };

    networking = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable TAP networking for the VM";
      };

      tapInterface = lib.mkOption {
        type = lib.types.str;
        default = "tap-redox";
        description = "TAP interface name";
      };

      hostAddress = lib.mkOption {
        type = lib.types.str;
        default = "172.16.0.1";
        description = "Host-side IP address";
      };

      guestAddress = lib.mkOption {
        type = lib.types.str;
        default = "172.16.0.2";
        description = "Guest-side IP address";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        default = "172.16.0.0/24";
        description = "Network subnet";
      };

      netmask = lib.mkOption {
        type = lib.types.int;
        default = 24;
        description = "Network prefix length (CIDR notation)";
      };

      guestMac = lib.mkOption {
        type = lib.types.str;
        default = "52:54:00:12:34:56";
        description = "Guest MAC address for TAP networking";
      };

      netQueues = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Number of virtio-net queues (2 = 1 RX + 1 TX)";
      };

      netQueueSize = lib.mkOption {
        type = lib.types.int;
        default = 256;
        description = "Size of each virtio-net queue";
      };
    };

    cpuTopology = lib.mkOption {
      type = lib.types.str;
      default = "1:2:1:2";
      description = "CPU topology for Cloud Hypervisor (threads_per_core:cores_per_die:dies_per_package:packages)";
    };

    pciSegments = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of PCI segments for Cloud Hypervisor";
    };

    mmio32ApertureWeight = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "32-bit MMIO aperture weight for Cloud Hypervisor PCI segment 0";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/redox-vm";
      description = "Directory for VM state (disk image copy, sockets)";
    };
  };

  config = lib.mkMerge [
    # Basic tools
    (lib.mkIf cfg.enable {
      environment.systemPackages = [
        redoxPkgs.fstools
        redoxPkgs.redox-rebuild
      ];
      programs.fuse.userAllowOther = true;

      # Binary cache for cross-compiled Redox packages (tailnet only).
      # harmonia on aspen1 serves pre-built relibc, kernel, base, userspace, etc.
      # Only reachable from machines on the tailnet.
      nix.settings = {
        extra-substituters = [ "http://aspen1:5000" ];
        extra-trusted-public-keys = [ "aspen1-1:hdbOqMbh1N/jLuqHVErDlrI7Wh9Cd/htzF7HUWYjQRc=" ];
      };
    })

    # VM service
    (lib.mkIf vmCfg.enable {
      boot.kernelModules = [
        "kvm-intel"
        "kvm-amd"
      ];

      networking = lib.mkIf vmCfg.networking.enable {
        bridges = { };
        interfaces.${vmCfg.networking.tapInterface} = {
          virtual = true;
          virtualType = "tap";
          ipv4.addresses = [
            {
              address = vmCfg.networking.hostAddress;
              prefixLength = vmCfg.networking.netmask;
            }
          ];
        };

        nat = {
          enable = true;
          internalInterfaces = [ vmCfg.networking.tapInterface ];
        };

        firewall.trustedInterfaces = [ vmCfg.networking.tapInterface ];
      };

      systemd.services.redox-vm = {
        description = "Redox OS Virtual Machine";
        wantedBy = lib.optional vmCfg.autoStart "multi-user.target";
        after = [
          "network.target"
        ]
        ++ lib.optional vmCfg.networking.enable "network-online.target";
        wants = lib.optional vmCfg.networking.enable "network-online.target";

        serviceConfig =
          let
            profileMap = {
              default = redoxPkgs.redox-default;
              minimal = redoxPkgs.redox-minimal;
              graphical = redoxPkgs.redox-graphical;
              cloud = redoxPkgs.redox-cloud;
            };
            diskImage = profileMap.${vmCfg.profile};
            cloudHypervisor = pkgs.cloud-hypervisor;
            firmware = pkgs.OVMF-cloud-hypervisor.fd;
          in
          {
            Type = "simple";
            StateDirectory = "redox-vm";
            RuntimeDirectory = "redox-vm";

            ExecStartPre = pkgs.writeShellScript "redox-vm-setup" ''
              if [ ! -f ${vmCfg.stateDir}/redox.img ]; then
                cp ${diskImage}/redox.img ${vmCfg.stateDir}/redox.img
                chmod 644 ${vmCfg.stateDir}/redox.img
              fi
            '';

            ExecStart =
              if vmCfg.vmm == "cloud-hypervisor" then
                let
                  netArgs = lib.optionalString vmCfg.networking.enable "--net tap=${vmCfg.networking.tapInterface},mac=${vmCfg.networking.guestMac},num_queues=${toString vmCfg.networking.netQueues},queue_size=${toString vmCfg.networking.netQueueSize}";
                in
                lib.concatStringsSep " " [
                  "${cloudHypervisor}/bin/cloud-hypervisor"
                  "--firmware ${firmware}/FV/CLOUDHV.fd"
                  "--disk path=${vmCfg.stateDir}/redox.img"
                  "--cpus boot=${toString vmCfg.cpus},topology=${vmCfg.cpuTopology}"
                  "--memory size=${toString vmCfg.memory}M"
                  "--platform num_pci_segments=${toString vmCfg.pciSegments}"
                  "--pci-segment pci_segment=0,mmio32_aperture_weight=${toString vmCfg.mmio32ApertureWeight}"
                  "--serial file=${vmCfg.stateDir}/serial.log"
                  "--console off"
                  "--api-socket path=/run/redox-vm/api.sock"
                  netArgs
                ]
              else
                lib.concatStringsSep " " [
                  "${pkgs.qemu}/bin/qemu-system-x86_64"
                  "-M pc -cpu host -enable-kvm"
                  "-m ${toString vmCfg.memory} -smp ${toString vmCfg.cpus}"
                  "-bios ${pkgs.OVMF.fd}/FV/OVMF.fd"
                  "-drive file=${vmCfg.stateDir}/redox.img,format=raw,if=none,id=disk0"
                  "-device virtio-blk-pci,drive=disk0"
                  "-serial file:${vmCfg.stateDir}/serial.log"
                  "-nographic"
                ];

            Restart = "on-failure";
            RestartSec = "10s";
          };
      };

      environment.systemPackages =
        let
          runnerMap = {
            default = redoxPkgs.run-redox-default;
            minimal = redoxPkgs.run-redox-minimal;
            graphical = redoxPkgs.run-redox-graphical-desktop;
            cloud = redoxPkgs.run-redox-cloud;
          };
        in
        [
          (runnerMap.${vmCfg.profile})
          redoxPkgs.redox-rebuild
        ];
    })
  ];
}
