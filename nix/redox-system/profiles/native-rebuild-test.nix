# Focused offline native system rebuild acceptance image.
# The bundle is seeded from the ordinary self-hosting system, not this test
# image, to avoid a disk-image -> bundle -> disk-image dependency cycle.
{ pkgs, lib }:

let
  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };
  proofService = marker: {
    description = "Native rebuild acceptance fixture";
    command = "/bin/echo";
    type = "oneshot";
    args = marker;
    wantedBy = "rootfs";
    enable = true;
    after = [ ];
    environment = { };
    priority = 50;
  };
in
selfHosting
// {
  "/boot" = (selfHosting."/boot" or { }) // {
    kernel = pkgs.native-boot-proof-kernel;
    bootloader = pkgs.native-boot-proof-bootloader;
    bootProof = true;
    # Vendored sources, tools, kernel build-std, initfs and failed build scratch.
    diskSizeMB = 16384;
  };

  "/environment" = selfHosting."/environment" // {
    # The retained init oneshot, not startup.sh, owns all three boot phases.
    systemPackages = builtins.filter (
      p: !(pkgs ? userutils && toString p == toString pkgs.userutils)
    ) (selfHosting."/environment".systemPackages or [ ]);
    etc = (selfHosting."/environment".etc or { }) // {
      "var/lib/redox-native-proof/runner.sh" = {
        text = builtins.readFile ../../pkgs/infrastructure/run-native-system-rebuild-test.sh;
        mode = "0755";
      };
    };
  };

  "/networking" = (selfHosting."/networking" or { }) // {
    enable = false;
    mode = "none";
  };

  "/hardware" = (selfHosting."/hardware" or { }) // {
    # The rebuild removes these optional drivers, keeping storage bootable.
    networkDrivers = [ "e1000d" ];
    usbEnable = true;
  };

  "/services" = (selfHosting."/services" or { }) // {
    services = (selfHosting."/services".services or { }) // {
      native-proof-remove = proofService "native-proof-remove-marker";
      native-proof-retain = proofService "native-proof-retain-marker";
      native-proof-runner = (proofService "") // {
        description = "Durable native system three-boot acceptance";
        # Activation replaces the profile; both interpreter and script must
        # remain reachable when the ordinary seed startup script is restored.
        command = "${pkgs.redox-bash}/bin/bash";
        args = "/var/lib/redox-native-proof/runner.sh";
        after = [ "native-proof-retain" ];
      };
    };
  };

  "/filesystem" = (selfHosting."/filesystem" or { }) // {
    extraPaths = (selfHosting."/filesystem".extraPaths or [ ]) ++ [
      {
        source = pkgs.native-system-bundle;
        target = "usr/src/nix-redox";
      }
      {
        source = pkgs.native-kernel-rebuild-bundle;
        target = "usr/src/native-kernel-rebuild";
      }
    ];
  };

  "/virtualisation" = (selfHosting."/virtualisation" or { }) // {
    memorySize = 8192;
    cpus = 4;
  };
}
