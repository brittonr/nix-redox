# Flake-parts module for NixOS integration
#
# Provides NixOS modules for:
# 1. programs.redox      — Install Redox development tools
# 2. programs.redox-dev  — Full development environment
# 3. services.redox-vm   — Declarative Redox VM management
#
# Usage in NixOS configuration:
#   {
#     inputs.redox.url = "github:user/redox";
#
#     nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#       modules = [
#         redox.nixosModules.default
#         {
#           programs.redox.enable = true;
#           services.redox-vm = {
#             enable = true;
#             autoStart = true;
#             profile = "default";
#             networking.enable = true;
#           };
#         }
#       ];
#     };
#   }

{ self, inputs, ... }:

{
  flake = {
    nixosModules = {
      default =
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

              # Enable FUSE for redoxfs
              programs.fuse.userAllowOther = true;
            })

            # VM service
            (lib.mkIf vmCfg.enable {
              # Ensure KVM is available
              boot.kernelModules = [
                "kvm-intel"
                "kvm-amd"
              ];

              # TAP networking setup
              networking = lib.mkIf vmCfg.networking.enable {
                bridges = { };
                interfaces.${vmCfg.networking.tapInterface} = {
                  virtual = true;
                  virtualType = "tap";
                  ipv4.addresses = [
                    {
                      address = vmCfg.networking.hostAddress;
                      prefixLength = 24;
                    }
                  ];
                };

                nat = {
                  enable = true;
                  internalInterfaces = [ vmCfg.networking.tapInterface ];
                };

                firewall.trustedInterfaces = [ vmCfg.networking.tapInterface ];
              };

              # Systemd service for the VM
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
                      # Copy disk image to state dir for writes
                      if [ ! -f ${vmCfg.stateDir}/redox.img ]; then
                        cp ${diskImage}/redox.img ${vmCfg.stateDir}/redox.img
                        chmod 644 ${vmCfg.stateDir}/redox.img
                      fi
                    '';

                    ExecStart =
                      if vmCfg.vmm == "cloud-hypervisor" then
                        let
                          netArgs = lib.optionalString vmCfg.networking.enable "--net tap=${vmCfg.networking.tapInterface},mac=52:54:00:12:34:56,num_queues=2,queue_size=256";
                        in
                        lib.concatStringsSep " " [
                          "${cloudHypervisor}/bin/cloud-hypervisor"
                          "--firmware ${firmware}/FV/CLOUDHV.fd"
                          "--disk path=${vmCfg.stateDir}/redox.img"
                          "--cpus boot=${toString vmCfg.cpus},topology=1:2:1:2"
                          "--memory size=${toString vmCfg.memory}M"
                          "--platform num_pci_segments=1"
                          "--pci-segment pci_segment=0,mmio32_aperture_weight=4"
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

              # Convenience: add runner scripts to PATH
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
        };

      # Development environment module (for contributors/hackers)
      development =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          redoxPkgs = self.packages.${pkgs.system};
        in
        {
          options.programs.redox-dev = {
            enable = lib.mkEnableOption "Full Redox OS development environment";
          };

          config = lib.mkIf config.programs.redox-dev.enable {
            environment.systemPackages = [
              # Host tools
              redoxPkgs.fstools
              redoxPkgs.redox-rebuild

              # Runner scripts
              redoxPkgs.run-redox-default
              redoxPkgs.run-redox-default-qemu
              redoxPkgs.run-redox-graphical-desktop

              # Additional useful tools
              pkgs.qemu
              pkgs.cloud-hypervisor
              pkgs.parted
              pkgs.mtools
              pkgs.dosfstools
            ];

            # Enable FUSE for redoxfs
            programs.fuse.userAllowOther = true;

            # Enable KVM
            boot.kernelModules = [
              "kvm-intel"
              "kvm-amd"
            ];
          };
        };
    };
  };
}
