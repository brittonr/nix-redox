# Activate Toplevel Integration Test
#
# Tests the nix-darwin-style activation pipeline:
#   - /etc/static symlink farm
#   - /run/current-system link
#   - /nix/var/nix/gcroots/current-system
#   - Per-file symlinks through /etc/static
#
# Test protocol:
#   FUNC_TESTS_START              -> suite starting
#   FUNC_TEST:<name>:PASS         -> test passed
#   FUNC_TEST:<name>:FAIL:<reason>-> test failed
#   FUNC_TESTS_COMPLETE           -> suite finished

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = builtins.readFile ../test-scripts/23-activate-toplevel.ion;

in
{
  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "snix"
      ++ opt "redox-bash";

    shellAliases = { };
  };

  "/networking" = {
    enable = true;
    mode = "auto";
  };

  "/services" = {
    startupScriptText = testScript;
  };

  "/boot" = {
    diskSizeMB = 896;
    initfsExcludeDaemons = [
      "rtcd"
      "hwd"
    ];
    banner = ''
      ==========================================
        Activate Toplevel Integration Test
      ==========================================
    '';
  };

  "/time" = {
    hostname = "activate-test";
  };
}
