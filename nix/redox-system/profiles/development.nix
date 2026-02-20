# Development RedoxOS Profile
#
# Full CLI: editors, utilities, networking with remote shell.
# Usage: redoxSystem { modules = [ ./profiles/development.nix ]; ... }

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "helix"
      ++ opt "binutils"
      ++ opt "extrautils"
      ++ opt "sodium"
      ++ opt "netutils"
      ++ opt "userutils"
      ++ opt "bat"
      ++ opt "hexyl"
      ++ opt "zoxide"
      ++ opt "dust"
      ++ opt "snix";

    shellAliases = {
      ls = "ls --color=auto";
      grep = "grep --color=auto";
      z = "zoxide query -- $@args && cd $(zoxide query -- $@args)";
    };

    # Include CLI tools in the local binary cache.
    # Users can install additional tools at runtime via `snix install <name>`.
    binaryCachePackages =
      lib.optionalAttrs (pkgs ? ripgrep) { ripgrep = pkgs.ripgrep; }
      // lib.optionalAttrs (pkgs ? fd) { fd = pkgs.fd; }
      // lib.optionalAttrs (pkgs ? bat) { bat = pkgs.bat; }
      // lib.optionalAttrs (pkgs ? hexyl) { hexyl = pkgs.hexyl; }
      // lib.optionalAttrs (pkgs ? zoxide) { zoxide = pkgs.zoxide; }
      // lib.optionalAttrs (pkgs ? dust) { dust = pkgs.dust; };
  };

  "/networking" = {
    enable = true;
    mode = "auto";
    remoteShellEnable = true;
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
      "bin/dash" = "/bin/ion";
      "bin/vi" = "/bin/sodium";
    };
  };

  # VM runner defaults for development
  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 2048;
    cpus = 4;
  };
}
