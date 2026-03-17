# My Redox OS Configuration
#
# This is like NixOS's configuration.nix — declare what your system
# should look like and `nix run` builds and boots it.
#
# Available modules:
#   /environment   — packages, shell aliases, env vars, etc files
#   /networking    — mode (auto/dhcp/static/none), DNS, interfaces
#   /graphics      — Orbital desktop enable, resolution
#   /hardware      — storage/network/graphics drivers, audio
#   /users         — user accounts and groups
#   /services      — typed services (ssh, httpd, getty), init scripts
#   /activation    — scripts that run on system switch
#   /security      — kernel scheme protection, passwords, setuid
#   /time          — hostname, timezone
#   /boot          — disk size, initfs size
#   /power         — ACPI, power button action
#   /logging       — log levels
#   /programs      — editor configs (ion, helix)
#   /filesystem    — extra dirs, symlinks
#   /virtualisation — VMM backend, memory, CPUs

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
{
  # ── System identity ──
  "/time" = {
    hostname = "my-redox";
    timezone = "America/New_York";
  };

  # ── Packages ──
  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "helix"
      ++ opt "snix"
      ++ opt "redox-bash"
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      ++ opt "userutils";

    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -la";
      e = "hx";
    };

    # Drop arbitrary files onto the disk
    etc = {
      "etc/motd" = {
        text = "Welcome to my custom Redox OS!";
      };
    };
  };

  # ── Graphics ──
  # Enable for Orbital desktop (requires `nix run .#graphical`)
  "/graphics".enable = false;

  # ── Networking ──
  "/networking" = {
    enable = true;
    mode = "auto";
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };

  # ── Users ──
  "/users" = {
    users = {
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
        realname = "Default User";
        createHome = true;
      };
    };
  };

  # ── Services ──
  "/services" = {
    # SSH server (requires redox-ssh in systemPackages)
    # ssh = {
    #   enable = true;
    #   port = 22;
    #   permitRootLogin = false;
    # };
  };

  # ── Activation scripts ──
  # Run in dependency order during `snix system switch`
  "/activation" = {
    scripts = {
      setup-dirs = {
        text = "mkdir -p /var/data";
        deps = [ ];
      };
      write-version = {
        text = "echo 1.0.0 > /var/data/version";
        deps = [ "setup-dirs" ];
      };
    };
  };

  # ── Hardware ──
  "/hardware" = {
    audioEnable = true;
  };

  # ── VM settings (only affects `nix run`, not the OS itself) ──
  "/virtualisation" = {
    memorySize = 2048;
    cpus = 4;
  };

  # ── Disk ──
  "/boot" = {
    diskSizeMB = 1024;
    initfsSizeMB = 128;
  };
}
