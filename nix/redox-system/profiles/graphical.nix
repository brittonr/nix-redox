# Graphical RedoxOS Profile
#
# Orbital desktop + audio, built on development profile.
# Usage: redoxSystem { modules = [ ./profiles/graphical.nix ]; ... }

{ pkgs, lib }:

let
  dev = import ./development.nix { inherit pkgs lib; };
in
dev
// {
  "/boot" = (dev."/boot" or { }) // {
    diskSizeMB = 1024;
    initfsSizeMB = 128;
  };

  "/graphics" = (dev."/graphics" or { }) // {
    enable = true;
  };

  "/hardware" = (dev."/hardware" or { }) // {
    audioEnable = true;
  };

  # Graphical profile requires passwords for orblogin authentication.
  # redox_users' verify_passwd panics on plaintext shadow entries,
  # so passwords MUST go through Argon2 hashing (handled by the build module).
  "/users" = (dev."/users" or { }) // {
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
}
