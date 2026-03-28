# Redox OS System Configuration
#
# This file defines your Redox system. Edit it and rebuild:
#   nix build
#
# See the full options reference:
#   nix build github:user/redox#optionsMarkdown
#
# Start from a profile and override what you need.

{ pkgs, lib }:

let
  # Base profile — pick one:
  #   minimal.nix      — bare shell, no networking
  #   development.nix  — shell tools, networking, helix editor
  #   graphical.nix    — Orbital desktop + audio
  #   self-hosting.nix — Rust toolchain on Redox
  base = import "${pkgs.redox-src or ./.}/nix/redox-system/profiles/development.nix" {
    inherit pkgs lib;
  };
in
base
// {
  # System identity
  "/system" = (base."/system" or { }) // {
    name = "my-redox";
    # stateVersion = 1;  # Bump when upgrading across breaking changes
  };

  # Users
  # "/users" = (base."/users" or {}) // {
  #   users = {
  #     root = {
  #       uid = 0; gid = 0;
  #       home = "/root"; shell = "/bin/ion";
  #       password = ""; createHome = true;
  #     };
  #     user = {
  #       uid = 1000; gid = 1000;
  #       home = "/home/user"; shell = "/bin/ion";
  #       password = ""; createHome = true;
  #     };
  #   };
  # };

  # Networking
  # "/networking" = (base."/networking" or {}) // {
  #   mode = "dhcp";
  #   dns = [ "1.1.1.1" "8.8.8.8" ];
  # };

  # Services
  # "/services" = (base."/services" or {}) // {
  #   ssh = { enable = true; port = 22; permitRootLogin = false;
  #           listenAddress = "0.0.0.0"; hostKeyPath = "/etc/ssh/host_key";
  #           authorizedKeysPath = "/etc/ssh/authorized_keys"; };
  # };

  # Environment
  # "/environment" = (base."/environment" or {}) // {
  #   shellAliases = (base."/environment".shellAliases or {}) // {
  #     ll = "ls -la";
  #   };
  #   variables = (base."/environment".variables or {}) // {
  #     EDITOR = "/bin/helix";
  #   };
  # };

  # Disk image size (MB)
  # "/boot" = (base."/boot" or {}) // {
  #   diskSizeMB = 896;
  # };
}
