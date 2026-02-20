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
      ++ opt "ripgrep"
      ++ opt "fd"
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

    # Include extra CLI tools in the local binary cache.
    # These are packages NOT in systemPackages that users can install
    # at runtime via `snix install <name>`.
    binaryCachePackages = { };
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
