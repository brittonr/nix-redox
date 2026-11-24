# Focused Guest Build Tools Test Profile
#
# Boots the self-hosting image and verifies the ported guest build tools
# (NASM, cbindgen, Python 3, Perl) and their parity/capability fixtures.

{ pkgs, lib }:

let
  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };

  startupScript = ''
    let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
    export PATH

    echo "FUNC_TESTS_START"
    /nix/system/profile/bin/bash /usr/src/build-tools/run-build-tools-test.sh
    echo "FUNC_TESTS_COMPLETE"
  '';
in
selfHosting
// {
  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = startupScript;
  };

  "/environment" = selfHosting."/environment" // {
    systemPackages = builtins.filter (
      p: !(pkgs ? userutils && toString p == toString pkgs.userutils)
    ) (selfHosting."/environment".systemPackages or [ ]);
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
        if pkgs ? build-tools-test-fixtures then
          [
            {
              source = pkgs.build-tools-test-fixtures;
              target = "usr/src/build-tools";
            }
          ]
        else
          [ ]
      );
  };
}
