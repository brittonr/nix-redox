# Graphical Redox OS — Orbital desktop with user login
#
# Full desktop environment with terminal, file manager, and editor.
# Boots into a graphical login screen via getty.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/time" = {
    hostname = "redox-desktop";
    timezone = "America/New_York";
  };

  "/environment" = {
    systemPackages =
      # Shell & coreutils
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "userutils"
      # Editors
      ++ opt "helix"
      # Desktop
      ++ opt "orbital"
      ++ opt "orbterm"
      ++ opt "orbutils"
      ++ opt "orbdata";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
    };
  };

  "/graphics" = {
    enable = true;
    resolution = "1280x800";
  };

  "/hardware".audioEnable = true;

  "/networking" = {
    enable = true;
    mode = "auto";
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };

  "/users".users = {
    root = {
      uid = 0;
      gid = 0;
      home = "/root";
      shell = "/bin/ion";
      password = "redox";
      realname = "root";
      createHome = true;
    };
    user = {
      uid = 1000;
      gid = 1000;
      home = "/home/user";
      shell = "/bin/ion";
      password = "redox";
      realname = "User";
      createHome = true;
    };
  };

  "/programs" = {
    helix = {
      enable = true;
      theme = "default";
    };
    editor = "/bin/hx";
  };

  "/boot" = {
    diskSizeMB = 1024;
    initfsSizeMB = 128;
  };

  "/virtualisation" = {
    memorySize = 2048;
    cpus = 4;
  };
}
