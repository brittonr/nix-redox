# NixOS modules for RedoxOS integration
#
# Provides:
# 1. programs.redox      — Install Redox development tools
# 2. services.redox-vm   — Declarative Redox VM management
# 3. programs.redox-dev  — Full development environment
#
# Usage in NixOS configuration:
#   {
#     inputs.redox.url = "github:user/redox";
#     nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#       modules = [
#         redox.nixosModules.default
#         { programs.redox.enable = true; }
#       ];
#     };
#   }

{ self }:

{
  default = import ./redox.nix { inherit self; };
  development = import ./development.nix { inherit self; };
}
