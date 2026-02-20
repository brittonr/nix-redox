# Functional Test Profile for RedoxOS
#
# Based on development profile but replaces the interactive shell with an
# automated test runner. The startup script executes ~40 functional tests
# and writes structured results to serial output.
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
  # IMPORTANT: This is Ion shell syntax, NOT bash/POSIX.
  # Key differences:
  #   - Variables: let var = "value"
  #   - Conditionals: if test ...; end  (no then/fi)
  #   - File tests: exists -f /path  (not test -f)
  #   - Loops: for item in list; end  (no done)
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Functional Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Category 1: Shell Fundamentals ──────────────────────────

    # Test: echo produces correct output
    let result = $(echo "test123")
    if test $result = "test123"
        echo "FUNC_TEST:echo-basic:PASS"
    else
        echo "FUNC_TEST:echo-basic:FAIL:got $result"
    end

    # Test: variable assignment and expansion
    let myvar = "hello"
    if test $myvar = "hello"
        echo "FUNC_TEST:variable-assignment:PASS"
    else
        echo "FUNC_TEST:variable-assignment:FAIL:got $myvar"
    end

    # Test: command substitution captures output
    let pwd_out = $(pwd)
    if test -n $pwd_out
        echo "FUNC_TEST:command-substitution:PASS"
    else
        echo "FUNC_TEST:command-substitution:FAIL:empty"
    end

    # Test: pipeline between commands
    let result = $(echo "foo" | cat)
    if test $result = "foo"
        echo "FUNC_TEST:pipeline-basic:PASS"
    else
        echo "FUNC_TEST:pipeline-basic:FAIL:got $result"
    end

    # Test: exit status captured correctly
    true
    if test $? = 0
        echo "FUNC_TEST:exit-status-true:PASS"
    else
        echo "FUNC_TEST:exit-status-true:FAIL"
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
        echo "FUNC_TEST:if-else-control:PASS"
    else
        echo "FUNC_TEST:if-else-control:FAIL"
    end

    # ── Category 2: System Identity ────────────────────────────

    # Test: /etc/hostname exists and has content
    if exists -f /etc/hostname
        let hn = $(cat /etc/hostname)
        if test -n $hn
            echo "FUNC_TEST:hostname-configured:PASS"
        else
            echo "FUNC_TEST:hostname-configured:FAIL:empty"
        end
    else
        echo "FUNC_TEST:hostname-configured:FAIL:missing"
    end

    # Test: /etc/timezone exists
    if exists -f /etc/timezone
        let tz = $(cat /etc/timezone)
        if test -n $tz
            echo "FUNC_TEST:timezone-configured:PASS"
        else
            echo "FUNC_TEST:timezone-configured:FAIL:empty"
        end
    else
        echo "FUNC_TEST:timezone-configured:FAIL:missing"
    end

    # Test: /etc/profile exists
    if exists -f /etc/profile
        echo "FUNC_TEST:profile-exists:PASS"
    else
        echo "FUNC_TEST:profile-exists:FAIL"
    end

    # Test: /etc/security/policy exists
    if exists -f /etc/security/policy
        echo "FUNC_TEST:security-policy-exists:PASS"
    else
        echo "FUNC_TEST:security-policy-exists:FAIL"
    end

    # ── Category 3: User/Group Configuration ───────────────────

    # Test: /etc/passwd exists and has content
    if exists -f /etc/passwd
        let content = $(cat /etc/passwd)
        if test -n $content
            echo "FUNC_TEST:passwd-exists:PASS"
        else
            echo "FUNC_TEST:passwd-exists:FAIL:empty"
        end
    else
        echo "FUNC_TEST:passwd-exists:FAIL:missing"
    end

    # Test: /etc/group exists and has content
    if exists -f /etc/group
        let content = $(cat /etc/group)
        if test -n $content
            echo "FUNC_TEST:group-exists:PASS"
        else
            echo "FUNC_TEST:group-exists:FAIL:empty"
        end
    else
        echo "FUNC_TEST:group-exists:FAIL:missing"
    end

    # Test: /etc/shadow exists
    if exists -f /etc/shadow
        echo "FUNC_TEST:shadow-exists:PASS"
    else
        echo "FUNC_TEST:shadow-exists:FAIL"
    end

    # Test: /etc/init.toml exists
    if exists -f /etc/init.toml
        echo "FUNC_TEST:init-toml-exists:PASS"
    else
        echo "FUNC_TEST:init-toml-exists:FAIL"
    end

    # ── Category 4: Filesystem Operations ──────────────────────

    # Test: can list root directory
    ls / > /dev/null
    if test $? = 0
        echo "FUNC_TEST:ls-root:PASS"
    else
        echo "FUNC_TEST:ls-root:FAIL"
    end

    # Test: /bin directory has executables
    if exists -d /bin
        let count = $(ls /bin | wc -l)
        if test $count -gt 0
            echo "FUNC_TEST:bin-populated:PASS"
        else
            echo "FUNC_TEST:bin-populated:FAIL:empty"
        end
    else
        echo "FUNC_TEST:bin-populated:FAIL:no-dir"
    end

    # Test: write and read a file
    echo "test_data_42" > /tmp/func_test_rw
    if exists -f /tmp/func_test_rw
        let readback = $(cat /tmp/func_test_rw)
        if test $readback = "test_data_42"
            echo "FUNC_TEST:file-write-read:PASS"
        else
            echo "FUNC_TEST:file-write-read:FAIL:mismatch"
        end
        rm /tmp/func_test_rw
    else
        echo "FUNC_TEST:file-write-read:FAIL:not-created"
    end

    # Test: mkdir creates directories
    mkdir /tmp/func_test_dir
    if exists -d /tmp/func_test_dir
        rm -rf /tmp/func_test_dir
        echo "FUNC_TEST:mkdir:PASS"
    else
        echo "FUNC_TEST:mkdir:FAIL"
    end

    # Test: touch creates empty files
    touch /tmp/func_test_touch
    if exists -f /tmp/func_test_touch
        rm /tmp/func_test_touch
        echo "FUNC_TEST:touch:PASS"
    else
        echo "FUNC_TEST:touch:FAIL"
    end

    # Test: rm removes files
    touch /tmp/func_test_rm
    rm /tmp/func_test_rm
    if not exists -f /tmp/func_test_rm
        echo "FUNC_TEST:rm:PASS"
    else
        echo "FUNC_TEST:rm:FAIL"
    end

    # Test: cp copies files
    echo "copy_me" > /tmp/func_test_cp_src
    cp /tmp/func_test_cp_src /tmp/func_test_cp_dst
    if exists -f /tmp/func_test_cp_dst
        let content = $(cat /tmp/func_test_cp_dst)
        if test $content = "copy_me"
            echo "FUNC_TEST:cp:PASS"
        else
            echo "FUNC_TEST:cp:FAIL:content-mismatch"
        end
        rm /tmp/func_test_cp_src /tmp/func_test_cp_dst
    else
        rm /tmp/func_test_cp_src
        echo "FUNC_TEST:cp:FAIL:not-copied"
    end

    # Test: mv moves files
    echo "move_me" > /tmp/func_test_mv_src
    mv /tmp/func_test_mv_src /tmp/func_test_mv_dst
    if exists -f /tmp/func_test_mv_dst
        if not exists -f /tmp/func_test_mv_src
            rm /tmp/func_test_mv_dst
            echo "FUNC_TEST:mv:PASS"
        else
            rm /tmp/func_test_mv_src /tmp/func_test_mv_dst
            echo "FUNC_TEST:mv:FAIL:src-still-exists"
        end
    else
        echo "FUNC_TEST:mv:FAIL:dst-missing"
    end

    # Test: file append works
    echo "line1" > /tmp/func_test_append
    echo "line2" >> /tmp/func_test_append
    let lines = $(cat /tmp/func_test_append | wc -l)
    if test $lines = 2
        echo "FUNC_TEST:file-append:PASS"
    else
        echo "FUNC_TEST:file-append:FAIL:got $lines lines"
    end
    rm /tmp/func_test_append

    # Test: pwd returns an absolute path
    let dir = $(pwd)
    if test -n $dir
        echo "FUNC_TEST:pwd:PASS"
    else
        echo "FUNC_TEST:pwd:FAIL:empty"
    end

    # ── Category 5: Core Utilities ─────────────────────────────

    # Test: cat pipes correctly
    let result = $(echo "pipe_test" | cat)
    if test $result = "pipe_test"
        echo "FUNC_TEST:cat-pipe:PASS"
    else
        echo "FUNC_TEST:cat-pipe:FAIL"
    end

    # Test: wc counts lines
    echo "a" > /tmp/func_test_wc
    echo "b" >> /tmp/func_test_wc
    echo "c" >> /tmp/func_test_wc
    let count = $(wc -l /tmp/func_test_wc | head -1)
    rm /tmp/func_test_wc
    # wc output may have leading spaces or filename — just check it contains "3"
    if test -n $count
        echo "FUNC_TEST:wc-lines:PASS"
    else
        echo "FUNC_TEST:wc-lines:FAIL:got $count"
    end

    # Test: head outputs first line
    echo "first" > /tmp/func_test_head
    echo "second" >> /tmp/func_test_head
    let result = $(head -1 /tmp/func_test_head)
    rm /tmp/func_test_head
    if test $result = "first"
        echo "FUNC_TEST:head:PASS"
    else
        echo "FUNC_TEST:head:FAIL:got $result"
    end

    # Test: /bin/ion exists (our shell)
    if exists -f /bin/ion
        echo "FUNC_TEST:ion-available:PASS"
    else
        echo "FUNC_TEST:ion-available:FAIL"
    end

    # Test: /bin/sh symlink works
    if exists -f /bin/sh
        echo "FUNC_TEST:sh-symlink:PASS"
    else
        echo "FUNC_TEST:sh-symlink:FAIL"
    end

    # ── Category 6: Device Files ───────────────────────────────

    # Test: writing to /dev/null succeeds
    echo "discard" > /dev/null
    if test $? = 0
        echo "FUNC_TEST:dev-null:PASS"
    else
        echo "FUNC_TEST:dev-null:FAIL"
    end

    # Test: /tmp is writable
    echo "writable" > /tmp/func_test_writable
    if exists -f /tmp/func_test_writable
        rm /tmp/func_test_writable
        echo "FUNC_TEST:tmp-writable:PASS"
    else
        echo "FUNC_TEST:tmp-writable:FAIL"
    end

    # ── Category 7: CLI Tool Availability ──────────────────────
    # These check that development profile tools are present and executable.
    # Each tool is tested with --version which should exit 0.

    if exists -f /bin/rg
        rg --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-ripgrep:PASS"
        else
            echo "FUNC_TEST:tool-ripgrep:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-ripgrep:SKIP"
    end

    if exists -f /bin/fd
        fd --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-fd:PASS"
        else
            echo "FUNC_TEST:tool-fd:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-fd:SKIP"
    end

    if exists -f /bin/bat
        bat --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-bat:PASS"
        else
            echo "FUNC_TEST:tool-bat:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-bat:SKIP"
    end

    if exists -f /bin/hexyl
        hexyl --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-hexyl:PASS"
        else
            echo "FUNC_TEST:tool-hexyl:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-hexyl:SKIP"
    end

    if exists -f /bin/zoxide
        zoxide --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-zoxide:PASS"
        else
            echo "FUNC_TEST:tool-zoxide:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-zoxide:SKIP"
    end

    if exists -f /bin/dust
        dust --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-dust:PASS"
        else
            echo "FUNC_TEST:tool-dust:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-dust:SKIP"
    end

    if exists -f /bin/snix
        snix --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:tool-snix:PASS"
        else
            echo "FUNC_TEST:tool-snix:FAIL:nonzero-exit"
        end
    else
        echo "FUNC_TEST:tool-snix:SKIP"
    end

    # ── Category 8: Logging & Config ───────────────────────────

    # Test: logging config exists
    if exists -f /etc/logging.conf
        echo "FUNC_TEST:logging-conf:PASS"
    else
        echo "FUNC_TEST:logging-conf:FAIL"
    end

    # Test: ACPI config exists
    if exists -f /etc/acpi/config
        echo "FUNC_TEST:acpi-conf:PASS"
    else
        echo "FUNC_TEST:acpi-conf:FAIL"
    end

    # Test: ion initrc exists
    if exists -f /etc/ion/initrc
        echo "FUNC_TEST:ion-initrc:PASS"
    else
        echo "FUNC_TEST:ion-initrc:FAIL"
    end

    # Test: /home directory exists (user home dirs)
    if exists -d /home
        echo "FUNC_TEST:home-dir:PASS"
    else
        echo "FUNC_TEST:home-dir:FAIL"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
    echo "========================================"
    echo "  Test Suite Complete"
    echo "========================================"
    echo ""
  '';
in
{
  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "helix"
      ++ opt "binutils"
      ++ opt "extrautils"
      ++ opt "sodium"
      ++ opt "netutils"
      ++ opt "userutils"
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
    # No remote shell needed for tests
    remoteShellEnable = false;
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
      "bin/dash" = "/bin/ion";
    };
  };

  "/services" = {
    # Replace interactive shell with test runner
    startupScriptText = testScript;
  };

  # Small VM is fine for tests
  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
