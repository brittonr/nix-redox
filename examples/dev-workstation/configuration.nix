# Dev Workstation — headless with developer tools
#
# Networking, snix package manager, Rust toolchain access, editor,
# and a login shell via getty. No graphics — connect over serial or
# remote shell.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  "/time" = {
    hostname = "dev";
    timezone = "UTC";
  };

  "/environment" = {
    systemPackages =
      # Shell & coreutils
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "userutils"
      ++ opt "redox-bash"
      # Editor
      ++ opt "helix"
      # Search & navigation
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      ++ opt "zoxide"
      ++ opt "hexyl"
      ++ opt "tokei"
      # Package manager
      ++ opt "snix"
      # Diff & patch
      ++ opt "redox-diffutils"
      ++ opt "redox-sed"
      ++ opt "redox-patch"
      ++ opt "gnu-make"
      # Debug
      ++ opt "strace-redox";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
      g = "rg";
    };

    variables = {
      PATH = "/bin:/usr/bin";
      HOME = "/root";
      USER = "root";
      SHELL = "/bin/ion";
      TERM = "xterm-256color";
      EDITOR = "/bin/hx";
    };
  };

  "/graphics".enable = false;
  "/hardware".audioEnable = false;

  "/networking" = {
    enable = true;
    mode = "auto";
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    remoteShellEnable = true;
  };

  "/programs" = {
    ion = {
      enable = true;
      prompt = "dev# ";
      initExtra = "";
    };
    helix = {
      enable = true;
      theme = "default";
    };
    editor = "/bin/hx";
  };

  "/snix" = {
    stored = {
      enable = true;
      cachePath = "/nix/cache";
      storeDir = "/nix/store";
    };
    profiled = {
      enable = true;
      profilesDir = "/nix/var/snix/profiles";
      storeDir = "/nix/store";
    };
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
    dev = {
      uid = 1000;
      gid = 1000;
      home = "/home/dev";
      shell = "/bin/ion";
      password = "redox";
      realname = "Developer";
      createHome = true;
    };
  };

  "/boot" = {
    diskSizeMB = 1536;
    initfsSizeMB = 128;
  };

  "/virtualisation" = {
    memorySize = 4096;
    cpus = 4;
  };
}
