# Opt-in self-hosting proof: the installed guest-built Snix builds Snix again.
#
# Imports the regular self-hosting test and adds /etc/snix-second-build.
{ pkgs, lib }:

let
  base = import ./self-hosting-test.nix { inherit pkgs lib; };
in
base
// {
  "/filesystem" = (base."/filesystem" or { }) // {
    extraPaths =
      (base."/filesystem".extraPaths or [ ])
      ++ [
        {
          source = pkgs.snix-second-build-marker;
          target = "etc/snix-second-build";
        }
      ];
  };
}
