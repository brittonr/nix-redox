# End-to-End Rebuild Integration Test
#
# Tests the FULL activate pipeline on a live Redox VM:
#   Phase 1: Verify initial state — etc files, activation markers exist
#   Phase 2: Rebuild with changes — hostname, new etc file, verify applied
#   Phase 3: No-op rebuild — same config again, verify no new generation
#   Phase 4: Rollback — restore original state, verify hostname reverted
#
# This covers features that unit tests cannot: real file I/O through
# the Redox scheme system, Ion shell interaction, and the activate
# pipeline running against a live rootfs.
#
# Test protocol:
#   FUNC_TESTS_START              -> suite starting
#   FUNC_TEST:<name>:PASS         -> test passed
#   FUNC_TEST:<name>:FAIL:<reason>-> test failed
#   FUNC_TESTS_COMPLETE           -> suite finished
#
# Usage: redoxSystem { modules = [ ./profiles/e2e-rebuild-test.nix ]; ... }

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = builtins.readFile ../test-scripts/21-e2e-rebuild.ion;

in
{
  "/environment" = {
    # No userutils — test runs as startup script, not via getty login
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "snix"
      ++ opt "redox-bash"
      ++ opt "redox-sed";

    shellAliases = { };

    # environment.etc: declare files that should land on disk at build time
    etc = {
      "etc/e2e-test/motd.txt" = {
        text = "E2E rebuild test environment";
        mode = "0644";
      };
      "etc/e2e-test/app-config.toml" = {
        text = "[test]\nenabled = true\nversion = 1\n";
        mode = "0644";
      };
    };
  };

  "/networking" = {
    enable = true;
    mode = "auto";
    remoteShellEnable = false;
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
      "bin/dash" = "/bin/ion";
    };
  };

  "/services" = {
    startupScriptText = testScript;
  };

  # Activation scripts: test dependency ordering and execution
  "/activation" = {
    scripts = {
      createE2eDirs = {
        text = "mkdir -p /var/e2e-test";
        deps = [];
      };
      writeE2eMarker = {
        text = "echo e2e-activation-ok > /var/e2e-test/marker";
        deps = [ "createE2eDirs" ];
      };
    };
  };

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
