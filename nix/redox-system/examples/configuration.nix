# Example RedoxOS Configuration (adios module system)
#
# Demonstrates how to configure a RedoxOS system using profiles and overrides.
#
# Usage in flake.nix:
#   mySystem = redoxSystemFactory.redoxSystem {
#     modules = [ ./configuration.nix ];
#     pkgs = redoxPackages;
#     hostPkgs = pkgs;
#   };
#
#   diskImage = mySystem.diskImage;

{ pkgs, lib }:

let
  # Start with the development profile
  dev = import ../profiles/development.nix { inherit pkgs lib; };
in
dev
// {
  # Add custom users
  "/users" = {
    users = {
      root = {
        uid = 0;
        gid = 0;
        home = "/root";
        shell = "/bin/ion";
        password = "";
        realname = "root";
        createHome = true;
      };
      user = {
        uid = 1000;
        gid = 1000;
        home = "/home/user";
        shell = "/bin/ion";
        password = "";
        realname = "Default User";
        createHome = true;
      };
      admin = {
        uid = 1001;
        gid = 1001;
        home = "/home/admin";
        shell = "/bin/ion";
        password = "redox";
        realname = "Admin";
        createHome = true;
      };
    };
    groups = {
      root = {
        gid = 0;
        members = [ ];
      };
      user = {
        gid = 1000;
        members = [ "user" ];
      };
      admin = {
        gid = 1001;
        members = [ "admin" ];
      };
    };
  };

  # Extend environment from dev profile
  "/environment" = (dev."/environment" or { }) // {
    systemPackages =
      (dev."/environment".systemPackages or [ ])
      ++ (if pkgs ? ripgrep then [ pkgs.ripgrep ] else [ ])
      ++ (if pkgs ? fd then [ pkgs.fd ] else [ ]);

    shellAliases = (dev."/environment".shellAliases or { }) // {
      ll = "ls -la";
      la = "ls -a";
      hx = "helix";
    };

    variables = (dev."/environment".variables or { }) // {
      EDITOR = "/bin/helix";
    };
  };

  # Custom init script
  "/services" = {
    initScripts = {
      "00_base" = {
        text = "notify /bin/ipcd";
        directory = "usr/lib/init.d";
      };
      "30_custom" = {
        text = ''echo "Custom initialization complete"'';
        directory = "init.d";
      };
    };
  };
}
