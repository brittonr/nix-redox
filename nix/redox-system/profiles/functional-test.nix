# Functional Test Profile for RedoxOS
#
# Based on development profile but replaces the interactive shell with an
# automated test runner. The startup script executes runtime tests that
# REQUIRE a live VM — shell execution, filesystem I/O, process execution.
#
# Static checks (config file existence, binary presence, passwd format)
# are handled by artifact tests in nix/tests/artifacts.nix — no VM needed.
#
# Test scripts are split into individual .ion files under test-scripts/,
# one per category. Nix inlines them at eval time. This structure allows:
#   - Focused editing: each file is 50-400 lines instead of 2900
#   - Category markers: serial output shows "--- XX-name.ion ---" banners
#   - Selective filtering: use --filter at the harness level to match tests
#
# Test protocol:
#   FUNC_TESTS_START              → suite starting
#   FUNC_TEST:<name>:PASS         → test passed
#   FUNC_TEST:<name>:FAIL:<reason>→ test failed
#   FUNC_TEST:<name>:SKIP         → test skipped
#   FUNC_TESTS_COMPLETE           → suite finished
#
# Usage: redoxSystem { modules = [ ./profiles/functional-test.nix ]; ... }

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  # ==========================================================================
  # Test scripts — each category is a separate .ion file installed to
  # /etc/test.d/. The runner iterates through them in sorted order.
  # Each runs in its own Ion process for crash isolation.
  # ==========================================================================

  # Read each test script from the source tree and embed it in the
  # startup script. At boot, the runner writes each to /tmp/test.d/
  # and executes them independently for crash isolation.
  testScriptFiles = builtins.filter
    (name: lib.hasSuffix ".ion" name)
    (builtins.attrNames (builtins.readDir ../test-scripts));

  testScriptContents = builtins.listToAttrs (
    builtins.map (name: {
      inherit name;
      value = builtins.readFile (../test-scripts + "/${name}");
    }) testScriptFiles
  );

  # ==========================================================================
  # Test runner — the startup script that orchestrates all test categories.
  # Each category is inlined from test-scripts/*.ion files. The source is
  # split into separate files for maintainability (each category ~50-400
  # lines instead of one 2900-line monolith). Category boundaries are
  # marked with "--- XX-name.ion ---" banners in serial output.
  # ==========================================================================

  # Sort script names so execution order is deterministic
  sortedScripts = builtins.sort (a: b: a < b) testScriptFiles;

  testRunner = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Functional Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # Run each test category inline. Source is split into separate files
    # in test-scripts/ for maintainability; Nix inlines them at eval time.
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
    # NOTE: Do NOT include "userutils" here.
    # When userutils (getty, login) is installed, startup.sh runs a login
    # loop instead of the test script, which means tests never execute.
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "helix"
      ++ opt "binutils"
      ++ opt "extrautils"
      ++ opt "sodium"
      ++ opt "netutils"
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      ++ opt "hexyl"
      ++ opt "zoxide"
      ++ opt "dust"
      ++ opt "snix"
      ++ opt "redox-bash";

    shellAliases = {
      ls = "ls --color=auto";
    };

    # Also include ripgrep and fd in the binary cache so the snix
    # install/remove tests can exercise the package manager flow.
    binaryCachePackages =
      lib.optionalAttrs (pkgs ? ripgrep) { ripgrep = pkgs.ripgrep; }
      // lib.optionalAttrs (pkgs ? fd) { fd = pkgs.fd; };

    # Test environment.etc: arbitrary file injection
    etc = {
      "etc/motd" = {
        text = "Welcome to Redox OS functional test environment!";
        mode = "0644";
      };
      "etc/myapp/config.toml" = {
        text = "[test]\nenabled = true\n";
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
    startupScriptText = testRunner;
  };

  # Test activation scripts: dependency ordering and execution
  "/activation" = {
    scripts = {
      createTestDirs = {
        text = "mkdir -p /var/test-data";
        deps = [];
      };
      writeTestMarker = {
        text = "echo activation-test-ok > /var/test-data/marker";
        deps = [ "createTestDirs" ];
      };
    };
  };

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
