# Development RedoxOS Profile
#
# A full-featured headless system with text editors, CLI tools,
# networking, and user management. Matches the current default diskImage.
#
# Usage:
#   redoxSystem { modules = [ ./profiles/development.nix ]; }

{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Collect available packages (graceful degradation if not built)
  opt = name: lib.optional (pkgs ? ${name}) pkgs.${name};
in
{
  # System packages matching current diskImage defaults
  redox.environment.systemPackages =
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
    ++ opt "dust";

  # Networking enabled with auto mode (DHCP + static fallback)
  redox.networking = {
    enable = true;
    mode = lib.mkDefault "auto";
    remoteShell.enable = lib.mkDefault true;
  };

  # Ion shell as /bin/sh and sodium as /bin/vi
  redox.filesystem.specialSymlinks = {
    "bin/sh" = "/bin/ion";
    "bin/dash" = "/bin/ion";
    "bin/vi" = "/bin/sodium";
  };

  # Zoxide alias
  redox.environment.shellAliases = {
    z = "zoxide query -- $@args && cd $(zoxide query -- $@args)";
  };
}
