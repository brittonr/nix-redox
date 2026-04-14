# Focused native kernel rebuild test profile
#
# Boots the self-hosting image and runs only the guest-native kernel rebuild
# proof path from the staged source bundle at /usr/src/native-kernel-rebuild.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };

  startupScript = ''
    let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
    export PATH

    /nix/system/profile/bin/bash /usr/src/native-kernel-rebuild/run-native-kernel-rebuild-test.sh
  '';
in
selfHosting
// {
  "/boot" = (selfHosting."/boot" or { }) // {
    # Source bundle + rust-src + target output for a kernel build need more room
    # than the regular self-hosting image.
    diskSizeMB = 12288;
  };

  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = startupScript;
  };

  "/environment" = selfHosting."/environment" // {
    systemPackages = builtins.filter (
      p: !(pkgs ? userutils && toString p == toString pkgs.userutils)
    ) (selfHosting."/environment".systemPackages or [ ])
    ++ opt "strace-redox";
  };

  "/filesystem" = (selfHosting."/filesystem" or { }) // {
    extraPaths =
      (
        if selfHosting ? "/filesystem" && selfHosting."/filesystem" ? extraPaths then
          selfHosting."/filesystem".extraPaths
        else
          [ ]
      )
      ++ (
        if pkgs ? native-kernel-rebuild-bundle then
          [
            {
              source = pkgs.native-kernel-rebuild-bundle;
              target = "usr/src/native-kernel-rebuild";
            }
          ]
        else
          [ ]
      );
  };

  "/virtualisation" = (selfHosting."/virtualisation" or { }) // {
    memorySize = 8192;
    cpus = 4;
  };
}
