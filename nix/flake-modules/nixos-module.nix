# Flake-parts module for NixOS integration
#
# This module exports a NixOS module that can be used to enable
# Redox OS development tools on a NixOS system.
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
        {
          options.programs.redox = {
            enable = lib.mkEnableOption "Redox OS development tools";
          };

          config = lib.mkIf config.programs.redox.enable {
            environment.systemPackages = [
              self.packages.${pkgs.system}.fstools
              self.packages.${pkgs.system}.runQemu
            ];

            # Enable FUSE for redoxfs
            programs.fuse.userAllowOther = true;
          };
        };

      # Development environment module
      development =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          options.programs.redox-dev = {
            enable = lib.mkEnableOption "Full Redox OS development environment";
          };

          config = lib.mkIf config.programs.redox-dev.enable {
            environment.systemPackages = with pkgs; [
              # Host tools
              self.packages.${pkgs.system}.fstools

              # Development tools
              self.packages.${pkgs.system}.runQemu
              self.packages.${pkgs.system}.runQemuGraphical

              # Additional useful tools
              qemu
              parted
              mtools
              dosfstools
            ];

            # Enable FUSE for redoxfs
            programs.fuse.userAllowOther = true;

            # Enable KVM for faster QEMU
            virtualisation.libvirtd.enable = lib.mkDefault false;
            security.polkit.enable = lib.mkDefault true;
          };
        };
    };
  };
}
