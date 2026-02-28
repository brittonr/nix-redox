# NixOS module: programs.redox-dev (full development environment)
{ self }:
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

    programs.fuse.userAllowOther = true;

    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
  };
}
