# Example RedoxOS Configuration
#
# This demonstrates how to configure a RedoxOS system using the module system.
# Place this file alongside your flake.nix and reference it in redoxSystem.
#
# Usage in flake.nix:
#   mySystem = redoxSystem {
#     modules = [ ./configuration.nix ];
#     pkgs = redoxPackages;
#     hostPkgs = pkgs;
#   };
#
#   diskImage = mySystem.diskImage;

{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Import a pre-built profile
  imports = [
    ../modules/profiles/development.nix
  ];

  # Users
  redox.users.users.admin = {
    uid = 1001;
    gid = 1001;
    home = "/home/admin";
    shell = "/bin/ion";
    password = "redox";
  };

  redox.users.groups.admin = {
    gid = 1001;
    members = [ "admin" ];
  };

  # Networking
  redox.networking = {
    enable = true;
    mode = "auto";
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    remoteShell.enable = true;
  };

  # Additional packages
  redox.environment.systemPackages =
    with pkgs;
    lib.optional (pkgs ? ripgrep) ripgrep ++ lib.optional (pkgs ? fd) fd;

  # Custom shell aliases
  redox.environment.shellAliases = {
    ll = "ls -la";
    la = "ls -a";
    hx = "helix";
  };

  # Custom environment variables
  redox.environment.variables = {
    EDITOR = "/bin/helix";
  };

  # Custom init script for application setup
  redox.services.initScripts."30_custom" = {
    text = ''
      echo "Custom initialization complete"
    '';
    directory = "init.d";
  };
}
