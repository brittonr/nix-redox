# Functional Smoke Test Profile for RedoxOS
#
# Fast subset of the functional test suite for host-side iteration.
# Covers only the early shell/filesystem/device/env scripts and omits
# unrelated packages and services.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  selectedScripts = [
    "01-shell.ion"
    "02-filesystem.ion"
    "03-devices.ion"
    "04-env.ion"
  ];

  testScriptContents = builtins.listToAttrs (
    builtins.map (name: {
      inherit name;
      value = builtins.readFile (../test-scripts + "/${name}");
    }) selectedScripts
  );

  testRunner = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Functional Smoke Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    ${lib.concatStringsSep "\n" (
      builtins.map (name:
        let content = testScriptContents.${name}; in
        ''
    echo "--- ${name} ---"
    ${content}
    echo ""
        ''
      ) selectedScripts
    )}

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/boot" = {
    diskSizeMB = 608;
    espSizeMB = 64;
    initfsExcludeDaemons = [
      "rtcd"
      "ptyd"
      "ipcd"
      "acpid"
      "lived"
    ];
  };

  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils";

    shellAliases = {
      ls = "ls --color=auto";
    };
  };

  "/networking" = {
    enable = false;
  };

  "/hardware" = {
    storageDrivers = [ "virtio-blkd" ];
    networkDrivers = [ ];
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
      "bin/dash" = "/bin/ion";
    };
  };

  "/services" = {
    startupScriptText = testRunner;
  };

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
