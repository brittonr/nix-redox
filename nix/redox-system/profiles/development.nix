# Development RedoxOS Profile
#
# Full CLI: editors, utilities, networking with remote shell.
# Includes self-hosting build tools (bash, make, git, diffutils, sed, patch).
# Usage: redoxSystem { modules = [ ./profiles/development.nix ]; ... }

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/environment" = {
    systemPackages =
      # Core shell and utilities
      opt "ion"
      ++ opt "uutils"
      ++ opt "helix"
      ++ opt "binutils"
      ++ opt "extrautils"
      ++ opt "sodium"
      ++ opt "netutils"
      ++ opt "userutils"
      # CLI tools
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      ++ opt "hexyl"
      ++ opt "zoxide"
      ++ opt "dust"
      ++ opt "tokei"
      ++ opt "lsd"
      ++ opt "shellharden"
      ++ opt "smith"
      ++ opt "exampled"
      # System management
      ++ opt "snix"
      ++ opt "redox-curl"
      # Build tools (small, useful for development)
      ++ opt "redox-bash"
      ++ opt "gnu-make"
      ++ opt "redox-git"
      ++ opt "redox-diffutils"
      ++ opt "redox-sed"
      ++ opt "redox-patch"
      ++ opt "strace-redox"
      ++ opt "contain"
      ++ opt "pkgutils";

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
