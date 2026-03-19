# Multi-User Test Profile for RedoxOS
#
# Tests per-user namespace configuration, file ownership setup,
# and security config generation. Validates that the module system
# produces correct login_schemes.toml, passwd, shadow, and group
# files for multi-user operation.
#
# This profile does NOT include userutils (getty/login) to keep the
# test runner simple — tests execute via startup.sh like functional-test.
# The 22-multi-user.ion test script validates config files and skips
# runtime identity tests (id/whoami) when userutils is absent.
#
# Test protocol matches functional-test:
#   FUNC_TESTS_START              -> suite starting
#   FUNC_TEST:<name>:PASS         -> test passed
#   FUNC_TEST:<name>:FAIL:<reason>-> test failed
#   FUNC_TEST:<name>:SKIP         -> test skipped
#   FUNC_TESTS_COMPLETE           -> suite finished

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScriptFiles = builtins.filter
    (name: lib.hasSuffix ".ion" name)
    (builtins.attrNames (builtins.readDir ../test-scripts));

  testScriptContents = builtins.listToAttrs (
    builtins.map (name: {
      inherit name;
      value = builtins.readFile (../test-scripts + "/${name}");
    }) testScriptFiles
  );

  sortedScripts = builtins.sort (a: b: a < b) testScriptFiles;

  testRunner = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Multi-User Test Suite"
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
      ) sortedScripts
    )}

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "snix"
      ++ opt "redox-bash";

    # Install the login_schemes test script as a system file.
    # Written as a bash script to avoid Ion quoting issues with $().
    etc = {
      "etc/test-login-schemes.sh" = {
        text = ''
          #!/bin/bash
          F=/etc/login_schemes.toml
          grep -q proc ''${F} && echo FUNC_TEST:login-schemes-root-proc:PASS || echo FUNC_TEST:login-schemes-root-proc:FAIL
          grep -q irq ''${F} && echo FUNC_TEST:login-schemes-has-irq:PASS || echo FUNC_TEST:login-schemes-has-irq:FAIL
          grep -q sys ''${F} && echo FUNC_TEST:login-schemes-has-sys:PASS || echo FUNC_TEST:login-schemes-has-sys:FAIL
          c=''$(grep -c irq ''${F})
          test "''${c}" = 1 && echo FUNC_TEST:login-schemes-user-no-irq:PASS || echo FUNC_TEST:login-schemes-user-no-irq:FAIL:count-''${c}
          c=''$(grep -c serio ''${F})
          test "''${c}" = 1 && echo FUNC_TEST:login-schemes-user-no-serio:PASS || echo FUNC_TEST:login-schemes-user-no-serio:FAIL:count-''${c}
          c=''$(grep -c file ''${F})
          test "''${c}" -ge 2 && echo FUNC_TEST:login-schemes-both-file:PASS || echo FUNC_TEST:login-schemes-both-file:FAIL:count-''${c}
          c=''$(grep -c pty ''${F})
          test "''${c}" -ge 2 && echo FUNC_TEST:login-schemes-both-pty:PASS || echo FUNC_TEST:login-schemes-both-pty:FAIL:count-''${c}
        '';
        mode = "0755";
      };
    };
  };

  "/users" = {
    users = {
      root = {
        uid = 0;
        gid = 0;
        home = "/root";
        shell = "/bin/ion";
        password = "";
        realname = "root";
        createHome = true;
      };
      user = {
        uid = 1000;
        gid = 1000;
        home = "/home/user";
        shell = "/bin/ion";
        password = "";
        realname = "Test User";
        createHome = true;
      };
    };

    groups = {
      root = {
        gid = 0;
        members = [ ];
      };
      user = {
        gid = 1000;
        members = [ "user" ];
      };
      sudo = {
        gid = 27;
        members = [ "user" ];
      };
    };
  };

  "/networking" = {
    enable = true;
    mode = "auto";
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
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
