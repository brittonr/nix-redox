# Native upstream Nixtamal proof, deliberately separate from the broad suite.
# The host builds archive/Git fixtures; all locking, fetching, hashing, loader
# evaluation, and generation-root checks happen inside the offline Redox guest.
{ pkgs, lib }:

{
  "/boot" = {
    diskSizeMB = 1024;
    espSizeMB = 64;
  };

  "/environment" = {
    systemPackages = [
      pkgs.ion
      pkgs.uutils
      pkgs.snix
      pkgs.nixtamal
      pkgs.redox-bash
      pkgs.redox-git
      pkgs.redox-curl
    ]
    ++ lib.optional (pkgs ? extrautils) pkgs.extrautils;
    shellAliases = { };
    motd = "";
  };

  "/networking" = {
    enable = false;
    mode = "none";
  };

  "/filesystem" = {
    extraDirectories = [
      "/tmp"
      "/nix/store"
    ];
    extraPaths = [
      {
        source = pkgs.nixtamal-test-fixtures;
        target = "usr/share/nixtamal-test";
      }
    ];
    specialSymlinks."bin/sh" = "/bin/ion";
  };

  "/services".startupScriptText = builtins.readFile ../test-scripts/nixtamal/lock-refresh.ion;

  "/snix" = {
    sandbox = false;
  };

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 2048;
    cpus = 2;
  };
}
