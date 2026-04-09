# SSH Test Profile for RedoxOS
#
# Based on development profile. Enables OpenSSH, a known root password, and
# QEMU SLiRP-friendly networking for the host-side ssh-test runner.

{ pkgs, lib }:

let
  dev = import ./development.nix { inherit pkgs lib; };
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];
in
dev
// {
  "/boot" = (dev."/boot" or { }) // {
    diskSizeMB = 1536;
    initfsSizeMB = 128;
  };

  "/environment" = (dev."/environment" or { }) // {
    systemPackages = (dev."/environment".systemPackages or [ ]) ++ opt "openssh";
  };

  "/services" = (dev."/services" or { }) // {
    ssh = {
      enable = true;
      port = 22;
      permitRootLogin = true;
      listenAddress = "0.0.0.0";
      hostKeyEd25519Path = "/etc/ssh/ssh_host_ed25519_key";
      hostKeyRsaPath = "/etc/ssh/ssh_host_rsa_key";
      hostKeyEcdsaPath = "/etc/ssh/ssh_host_ecdsa_key";
      authorizedKeysPath = "/etc/ssh/authorized_keys";
    };
  };

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
    };
  };

  "/virtualisation" = (dev."/virtualisation" or { }) // {
    vmm = "qemu";
    memorySize = 2048;
    cpus = 4;
  };
}
