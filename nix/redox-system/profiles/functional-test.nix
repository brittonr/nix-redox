# Functional Test Profile for RedoxOS
#
# Based on development profile but replaces the interactive shell with an
# automated test runner. The startup script executes runtime tests that
# REQUIRE a live VM — shell execution, filesystem I/O, process execution.
#
# Static checks (config file existence, binary presence, passwd format)
# are handled by artifact tests in nix/tests/artifacts.nix — no VM needed.
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
  # Ion shell test suite — runs inside the Redox guest
  #
  # ONLY tests that require a running OS belong here:
  #   - Shell actually parses and executes Ion syntax
  #   - Filesystem I/O works on a live RedoxFS
  #   - Cross-compiled binaries actually run
  #   - Device files are functional
  #
  # IMPORTANT: Ion shell syntax, NOT bash/POSIX.
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Functional Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Shell Execution ────────────────────────────────────────
    # These verify Ion shell actually works on the running kernel.

    # Test: echo produces correct output
    let result = $(echo "test123")
    if test $result = "test123"
        echo "FUNC_TEST:echo:PASS"
    else
        echo "FUNC_TEST:echo:FAIL:got $result"
    end

    # Test: variable assignment and expansion
    let myvar = "hello"
    if test $myvar = "hello"
        echo "FUNC_TEST:variables:PASS"
    else
        echo "FUNC_TEST:variables:FAIL:got $myvar"
    end

    # Test: command substitution captures output
    let pwd_out = $(pwd)
    if test -n $pwd_out
        echo "FUNC_TEST:substitution:PASS"
    else
        echo "FUNC_TEST:substitution:FAIL:empty"
    end

    # Test: pipeline between processes
    let result = $(echo "foo" | cat)
    if test $result = "foo"
        echo "FUNC_TEST:pipeline:PASS"
    else
        echo "FUNC_TEST:pipeline:FAIL:got $result"
    end

    # Test: exit status captured
    true
    if test $? = 0
        echo "FUNC_TEST:exit-status:PASS"
    else
        echo "FUNC_TEST:exit-status:FAIL"
    end

    # Test: if/else control flow
    let val = "expected"
    let passed = "no"
    if test $val = "expected"
        let passed = "yes"
    else
        let passed = "no"
    end
    if test $passed = "yes"
        echo "FUNC_TEST:if-else:PASS"
    else
        echo "FUNC_TEST:if-else:FAIL"
    end

    # ── Filesystem I/O ─────────────────────────────────────────
    # These verify RedoxFS read/write works at runtime.

    # Test: write and read back a file
    echo "test_data_42" > /tmp/func_rw
    if exists -f /tmp/func_rw
        let readback = $(cat /tmp/func_rw)
        if test $readback = "test_data_42"
            echo "FUNC_TEST:file-roundtrip:PASS"
        else
            echo "FUNC_TEST:file-roundtrip:FAIL:mismatch"
        end
        rm /tmp/func_rw
    else
        echo "FUNC_TEST:file-roundtrip:FAIL:not-created"
    end

    # Test: mkdir + rmdir
    mkdir /tmp/func_dir
    if exists -d /tmp/func_dir
        rm -rf /tmp/func_dir
        echo "FUNC_TEST:mkdir:PASS"
    else
        echo "FUNC_TEST:mkdir:FAIL"
    end

    # Test: touch creates file
    touch /tmp/func_touch
    if exists -f /tmp/func_touch
        rm /tmp/func_touch
        echo "FUNC_TEST:touch:PASS"
    else
        echo "FUNC_TEST:touch:FAIL"
    end

    # Test: rm removes file
    touch /tmp/func_rm
    rm /tmp/func_rm
    if not exists -f /tmp/func_rm
        echo "FUNC_TEST:rm:PASS"
    else
        echo "FUNC_TEST:rm:FAIL"
    end

    # Test: cp copies file content
    echo "copy_me" > /tmp/func_cp_src
    cp /tmp/func_cp_src /tmp/func_cp_dst
    if exists -f /tmp/func_cp_dst
        let content = $(cat /tmp/func_cp_dst)
        rm /tmp/func_cp_src /tmp/func_cp_dst
        if test $content = "copy_me"
            echo "FUNC_TEST:cp:PASS"
        else
            echo "FUNC_TEST:cp:FAIL:content"
        end
    else
        rm /tmp/func_cp_src
        echo "FUNC_TEST:cp:FAIL:missing"
    end

    # Test: mv moves file (src gone, dst exists)
    echo "move_me" > /tmp/func_mv_src
    mv /tmp/func_mv_src /tmp/func_mv_dst
    if exists -f /tmp/func_mv_dst
        if not exists -f /tmp/func_mv_src
            rm /tmp/func_mv_dst
            echo "FUNC_TEST:mv:PASS"
        else
            rm /tmp/func_mv_src /tmp/func_mv_dst
            echo "FUNC_TEST:mv:FAIL:src-exists"
        end
    else
        echo "FUNC_TEST:mv:FAIL:dst-missing"
    end

    # Test: file append
    echo "line1" > /tmp/func_append
    echo "line2" >> /tmp/func_append
    let lines = $(wc -l /tmp/func_append)
    rm /tmp/func_append
    if test -n $lines
        echo "FUNC_TEST:append:PASS"
    else
        echo "FUNC_TEST:append:FAIL"
    end

    # ── Device Files ───────────────────────────────────────────

    # Test: /dev/null accepts writes
    echo "discard" > /dev/null
    if test $? = 0
        echo "FUNC_TEST:dev-null:PASS"
    else
        echo "FUNC_TEST:dev-null:FAIL"
    end

    # Test: /tmp is writable (ramfs mounted)
    echo "writable" > /tmp/func_writable
    if exists -f /tmp/func_writable
        rm /tmp/func_writable
        echo "FUNC_TEST:tmp-writable:PASS"
    else
        echo "FUNC_TEST:tmp-writable:FAIL"
    end

    # ── CLI Tool Execution ─────────────────────────────────────
    # These verify cross-compiled binaries actually run on Redox.
    # SKIP if binary not present (profile may vary).

    if exists -f /bin/rg
        rg --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-rg:PASS"
        else
            echo "FUNC_TEST:run-rg:FAIL"
        end
    else
        echo "FUNC_TEST:run-rg:SKIP"
    end

    if exists -f /bin/fd
        fd --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-fd:PASS"
        else
            echo "FUNC_TEST:run-fd:FAIL"
        end
    else
        echo "FUNC_TEST:run-fd:SKIP"
    end

    if exists -f /bin/bat
        bat --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-bat:PASS"
        else
            echo "FUNC_TEST:run-bat:FAIL"
        end
    else
        echo "FUNC_TEST:run-bat:SKIP"
    end

    if exists -f /bin/hexyl
        hexyl --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-hexyl:PASS"
        else
            echo "FUNC_TEST:run-hexyl:FAIL"
        end
    else
        echo "FUNC_TEST:run-hexyl:SKIP"
    end

    if exists -f /bin/zoxide
        zoxide --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-zoxide:PASS"
        else
            echo "FUNC_TEST:run-zoxide:FAIL"
        end
    else
        echo "FUNC_TEST:run-zoxide:SKIP"
    end

    if exists -f /bin/dust
        dust --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-dust:PASS"
        else
            echo "FUNC_TEST:run-dust:FAIL"
        end
    else
        echo "FUNC_TEST:run-dust:SKIP"
    end

    if exists -f /bin/snix
        snix --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-snix:PASS"
        else
            echo "FUNC_TEST:run-snix:FAIL"
        end
    else
        echo "FUNC_TEST:run-snix:SKIP"
    end

    # ── System Manifest Introspection ─────────────────────────
    # These verify `snix system` reads the embedded manifest.
    # NOTE: Ion shell has different redirection syntax from bash.
    # Use simple patterns — avoid complex command substitution + redirect combos.

    # Test: manifest.json exists on disk
    if exists -f /etc/redox-system/manifest.json
        echo "FUNC_TEST:manifest-exists:PASS"
    else
        echo "FUNC_TEST:manifest-exists:FAIL"
    end

    if exists -f /bin/snix
        # Test: snix system info runs successfully
        # Ion: > for stdout, ^> for stderr (NOT 1> / 2> like bash)
        /bin/snix system info -m /etc/redox-system/manifest.json > /tmp/sys_info ^> /tmp/sys_err
        if test $? = 0
            echo "FUNC_TEST:snix-system-info:PASS"
        else
            echo "FUNC_TEST:snix-system-info:FAIL"
        end

        # Test: info output contains Hostname
        grep -q Hostname /tmp/sys_info
        if test $? = 0
            echo "FUNC_TEST:snix-info-hostname:PASS"
        else
            echo "FUNC_TEST:snix-info-hostname:FAIL"
        end

        # Test: info output contains Packages
        grep -q Packages /tmp/sys_info
        if test $? = 0
            echo "FUNC_TEST:snix-info-packages:PASS"
        else
            echo "FUNC_TEST:snix-info-packages:FAIL"
        end

        # Test: info output shows tracked files
        grep -q tracked /tmp/sys_info
        if test $? = 0
            echo "FUNC_TEST:snix-info-files:PASS"
        else
            echo "FUNC_TEST:snix-info-files:FAIL"
        end

        # Test: info output shows generation info
        grep -q Generation /tmp/sys_info
        if test $? = 0
            echo "FUNC_TEST:snix-info-generation:PASS"
        else
            echo "FUNC_TEST:snix-info-generation:FAIL"
        end

        rm /tmp/sys_info
        rm /tmp/sys_err

        # Test: snix system verify runs (may find modified files from runtime changes)
        /bin/snix system verify -m /etc/redox-system/manifest.json > /tmp/sys_verify ^> /tmp/sys_verr
        # Even if verify fails (runtime changes), it should produce "Verifying" output
        grep -q Verifying /tmp/sys_verify
        if test $? = 0
            echo "FUNC_TEST:snix-system-verify:PASS"
        else
            echo "FUNC_TEST:snix-system-verify:FAIL"
        end
        rm /tmp/sys_verify
        rm /tmp/sys_verr

        # ── Generation Management ─────────────────────────────
        # Test: generations directory exists and has generation 1
        if exists -d /etc/redox-system/generations/1
            echo "FUNC_TEST:generation-dir-exists:PASS"
        else
            echo "FUNC_TEST:generation-dir-exists:FAIL"
        end

        if exists -f /etc/redox-system/generations/1/manifest.json
            echo "FUNC_TEST:generation-1-manifest:PASS"
        else
            echo "FUNC_TEST:generation-1-manifest:FAIL"
        end

        # Test: snix system generations lists at least one generation
        /bin/snix system generations > /tmp/sys_gens ^> /tmp/sys_gens_err
        if test $? = 0
            echo "FUNC_TEST:snix-system-generations:PASS"
        else
            echo "FUNC_TEST:snix-system-generations:FAIL"
        end

        # Test: generations output contains header
        grep -q "System Generations" /tmp/sys_gens
        if test $? = 0
            echo "FUNC_TEST:snix-generations-header:PASS"
        else
            echo "FUNC_TEST:snix-generations-header:FAIL"
        end

        # Test: generations output shows at least 1 stored generation
        grep -q "Generations stored" /tmp/sys_gens
        if test $? = 0
            echo "FUNC_TEST:snix-generations-count:PASS"
        else
            echo "FUNC_TEST:snix-generations-count:FAIL"
        end

        rm /tmp/sys_gens
        rm /tmp/sys_gens_err

        # Test: snix system switch works (create a modified manifest, switch to it)
        cp /etc/redox-system/manifest.json /tmp/new_manifest.json
        /bin/snix system switch /tmp/new_manifest.json -D "test switch" --gen-dir /tmp/test_gens --manifest /tmp/switch_test.json ^> /tmp/switch_err
        # This will fail because /tmp/switch_test.json doesn't exist yet as "current"
        # Instead, test switch with a proper setup:
        cp /etc/redox-system/manifest.json /tmp/switch_current.json
        /bin/snix system switch /tmp/new_manifest.json -D "test switch" --gen-dir /tmp/test_gens --manifest /tmp/switch_current.json > /tmp/switch_out ^> /tmp/switch_err
        if test $? = 0
            echo "FUNC_TEST:snix-system-switch:PASS"
        else
            echo "FUNC_TEST:snix-system-switch:FAIL"
        end

        # Verify switch created generation entries
        if exists -d /tmp/test_gens/1
            echo "FUNC_TEST:switch-saves-old-gen:PASS"
        else
            echo "FUNC_TEST:switch-saves-old-gen:FAIL"
        end

        if exists -d /tmp/test_gens/2
            echo "FUNC_TEST:switch-creates-new-gen:PASS"
        else
            echo "FUNC_TEST:switch-creates-new-gen:FAIL"
        end

        rm /tmp/new_manifest.json
        rm /tmp/switch_current.json
        rm /tmp/switch_out
        rm /tmp/switch_err
    else
        echo "FUNC_TEST:snix-system-info:SKIP"
        echo "FUNC_TEST:snix-info-hostname:SKIP"
        echo "FUNC_TEST:snix-info-packages:SKIP"
        echo "FUNC_TEST:snix-info-files:SKIP"
        echo "FUNC_TEST:snix-info-generation:SKIP"
        echo "FUNC_TEST:snix-system-verify:SKIP"
        echo "FUNC_TEST:generation-dir-exists:SKIP"
        echo "FUNC_TEST:generation-1-manifest:SKIP"
        echo "FUNC_TEST:snix-system-generations:SKIP"
        echo "FUNC_TEST:snix-generations-header:SKIP"
        echo "FUNC_TEST:snix-generations-count:SKIP"
        echo "FUNC_TEST:snix-system-switch:SKIP"
        echo "FUNC_TEST:switch-saves-old-gen:SKIP"
        echo "FUNC_TEST:switch-creates-new-gen:SKIP"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    # NOTE: Do NOT include "userutils" here.
    # When userutils (getty, login) is installed, init runs getty instead of
    # /startup.sh, which means the test script never executes.
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "helix"
      ++ opt "binutils"
      ++ opt "extrautils"
      ++ opt "sodium"
      ++ opt "netutils"
      ++ opt "bat"
      ++ opt "hexyl"
      ++ opt "zoxide"
      ++ opt "dust"
      ++ opt "snix";

    shellAliases = {
      ls = "ls --color=auto";
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

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
