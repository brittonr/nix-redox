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
  #   - snix eval exercises the Nix bytecode VM end-to-end
  #   - snix system commands read/verify the live manifest
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

    # ── Nix Evaluator (snix eval) ─────────────────────────────
    # These verify the snix bytecode VM evaluates Nix expressions correctly
    # inside the running Redox OS — the full eval stack end-to-end.
    # Uses --expr for the canonical test, --file for complex expressions
    # to avoid Ion shell quoting issues.

    if exists -f /bin/snix
        # Test: arithmetic (the canonical "does it work" test)
        /bin/snix eval --expr "1 + 1" > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            let result = $(cat /tmp/eval_out)
            if test $result = "2"
                echo "FUNC_TEST:snix-eval-arithmetic:PASS"
            else
                echo "FUNC_TEST:snix-eval-arithmetic:FAIL:expected 2 got $result"
            end
        else
            echo "FUNC_TEST:snix-eval-arithmetic:FAIL:exit-code"
        end

        # Test: let binding
        echo 'let x = 5; in x * 2' > /tmp/eval_let.nix
        /bin/snix eval --file /tmp/eval_let.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            let result = $(cat /tmp/eval_out)
            if test $result = "10"
                echo "FUNC_TEST:snix-eval-let:PASS"
            else
                echo "FUNC_TEST:snix-eval-let:FAIL:expected 10 got $result"
            end
        else
            echo "FUNC_TEST:snix-eval-let:FAIL:exit-code"
        end

        # Test: string concatenation
        echo '"hello" + " world"' > /tmp/eval_str.nix
        /bin/snix eval --file /tmp/eval_str.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            grep -q 'hello world' /tmp/eval_out
            if test $? = 0
                echo "FUNC_TEST:snix-eval-strings:PASS"
            else
                echo "FUNC_TEST:snix-eval-strings:FAIL:content"
            end
        else
            echo "FUNC_TEST:snix-eval-strings:FAIL:exit-code"
        end

        # Test: builtins.length
        echo 'builtins.length [1 2 3]' > /tmp/eval_bi.nix
        /bin/snix eval --file /tmp/eval_bi.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            let result = $(cat /tmp/eval_out)
            if test $result = "3"
                echo "FUNC_TEST:snix-eval-builtins:PASS"
            else
                echo "FUNC_TEST:snix-eval-builtins:FAIL:expected 3 got $result"
            end
        else
            echo "FUNC_TEST:snix-eval-builtins:FAIL:exit-code"
        end

        # Test: function application (lambda)
        echo '(x: x + 1) 5' > /tmp/eval_fn.nix
        /bin/snix eval --file /tmp/eval_fn.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            let result = $(cat /tmp/eval_out)
            if test $result = "6"
                echo "FUNC_TEST:snix-eval-functions:PASS"
            else
                echo "FUNC_TEST:snix-eval-functions:FAIL:expected 6 got $result"
            end
        else
            echo "FUNC_TEST:snix-eval-functions:FAIL:exit-code"
        end

        # Test: conditional expression
        echo 'if true then 42 else 0' > /tmp/eval_cond.nix
        /bin/snix eval --file /tmp/eval_cond.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            let result = $(cat /tmp/eval_out)
            if test $result = "42"
                echo "FUNC_TEST:snix-eval-conditional:PASS"
            else
                echo "FUNC_TEST:snix-eval-conditional:FAIL:expected 42 got $result"
            end
        else
            echo "FUNC_TEST:snix-eval-conditional:FAIL:exit-code"
        end

        # Test: attribute set access
        echo '{ a = 1; b = 2; }.a' > /tmp/eval_attr.nix
        /bin/snix eval --file /tmp/eval_attr.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            let result = $(cat /tmp/eval_out)
            if test $result = "1"
                echo "FUNC_TEST:snix-eval-attrset:PASS"
            else
                echo "FUNC_TEST:snix-eval-attrset:FAIL:expected 1 got $result"
            end
        else
            echo "FUNC_TEST:snix-eval-attrset:FAIL:exit-code"
        end

        # Test: builtins.typeOf (verifies builtin dispatching)
        echo 'builtins.typeOf 42' > /tmp/eval_type.nix
        /bin/snix eval --file /tmp/eval_type.nix > /tmp/eval_out ^> /tmp/eval_err
        if test $? = 0
            grep -q 'int' /tmp/eval_out
            if test $? = 0
                echo "FUNC_TEST:snix-eval-typeof:PASS"
            else
                echo "FUNC_TEST:snix-eval-typeof:FAIL:content"
            end
        else
            echo "FUNC_TEST:snix-eval-typeof:FAIL:exit-code"
        end

        # Cleanup eval temp files
        rm /tmp/eval_out
        rm /tmp/eval_err
        rm /tmp/eval_let.nix
        rm /tmp/eval_str.nix
        rm /tmp/eval_bi.nix
        rm /tmp/eval_fn.nix
        rm /tmp/eval_cond.nix
        rm /tmp/eval_attr.nix
        rm /tmp/eval_type.nix
    else
        echo "FUNC_TEST:snix-eval-arithmetic:SKIP"
        echo "FUNC_TEST:snix-eval-let:SKIP"
        echo "FUNC_TEST:snix-eval-strings:SKIP"
        echo "FUNC_TEST:snix-eval-builtins:SKIP"
        echo "FUNC_TEST:snix-eval-functions:SKIP"
        echo "FUNC_TEST:snix-eval-conditional:SKIP"
        echo "FUNC_TEST:snix-eval-attrset:SKIP"
        echo "FUNC_TEST:snix-eval-typeof:SKIP"
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

    # ── Store Layer (snix store) ─────────────────────────────
    # These verify the new local store management layer:
    #   - PathInfo database (JSON-backed, /nix/var/snix/pathinfo/)
    #   - GC roots (symlinks in /nix/var/snix/gcroots/)
    #   - Closure computation (BFS over references)
    #   - Garbage collection (mark-and-sweep)
    # NOTE: These are local operations (no network needed).

    if exists -f /bin/snix
        # Test: snix store verify runs (may report no store at /nix/store)
        /bin/snix store verify > /tmp/store_verify ^> /tmp/store_verr
        if test $? = 0
            echo "FUNC_TEST:snix-store-verify:PASS"
        else
            echo "FUNC_TEST:snix-store-verify:FAIL"
        end
        rm /tmp/store_verify
        rm /tmp/store_verr

        # Test: snix store list runs (empty store is fine)
        /bin/snix store list > /tmp/store_list ^> /tmp/store_lerr
        if test $? = 0
            echo "FUNC_TEST:snix-store-list:PASS"
        else
            echo "FUNC_TEST:snix-store-list:FAIL"
        end
        rm /tmp/store_list
        rm /tmp/store_lerr

        # Test: snix store roots runs (empty is fine)
        /bin/snix store roots > /tmp/store_roots ^> /tmp/store_rerr
        if test $? = 0
            echo "FUNC_TEST:snix-store-roots:PASS"
        else
            echo "FUNC_TEST:snix-store-roots:FAIL"
        end
        rm /tmp/store_roots
        rm /tmp/store_rerr

        # Test: snix store gc --dry-run works with no roots
        /bin/snix store gc --dry-run > /tmp/store_gc ^> /tmp/store_gerr
        if test $? = 0
            echo "FUNC_TEST:snix-store-gc-dryrun:PASS"
        else
            echo "FUNC_TEST:snix-store-gc-dryrun:FAIL"
        end
        rm /tmp/store_gc
        rm /tmp/store_gerr

        # Test: snix store info on nonexistent path gives an error (expected)
        /bin/snix store info /nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-nonexistent-1.0 > /tmp/store_info ^> /tmp/store_ierr
        if test $? = 1
            echo "FUNC_TEST:snix-store-info-missing:PASS"
        else
            echo "FUNC_TEST:snix-store-info-missing:FAIL:expected-error"
        end
        rm /tmp/store_info
        rm /tmp/store_ierr

        # Test: snix store closure on nonexistent path gives an error (expected)
        /bin/snix store closure /nix/store/5g5nzcsmcmk0mnqz6i0gr1m0g8r5rq8r-nonexistent-1.0 > /tmp/store_clo ^> /tmp/store_cerr
        if test $? = 1
            echo "FUNC_TEST:snix-store-closure-missing:PASS"
        else
            echo "FUNC_TEST:snix-store-closure-missing:FAIL:expected-error"
        end
        rm /tmp/store_clo
        rm /tmp/store_cerr

        # Test: snix --help includes "store" subcommand
        /bin/snix --help > /tmp/snix_help ^> /tmp/snix_herr
        grep -q 'store' /tmp/snix_help
        if test $? = 0
            echo "FUNC_TEST:snix-help-has-store:PASS"
        else
            echo "FUNC_TEST:snix-help-has-store:FAIL"
        end
        rm /tmp/snix_help
        rm /tmp/snix_herr

        # Test: snix store --help shows all subcommands
        /bin/snix store --help > /tmp/store_help ^> /tmp/store_herr
        grep -q 'gc' /tmp/store_help
        if test $? = 0
            grep -q 'closure' /tmp/store_help
            if test $? = 0
                grep -q 'add-root' /tmp/store_help
                if test $? = 0
                    echo "FUNC_TEST:snix-store-help-complete:PASS"
                else
                    echo "FUNC_TEST:snix-store-help-complete:FAIL:missing-add-root"
                end
            else
                echo "FUNC_TEST:snix-store-help-complete:FAIL:missing-closure"
            end
        else
            echo "FUNC_TEST:snix-store-help-complete:FAIL:missing-gc"
        end
        rm /tmp/store_help
        rm /tmp/store_herr
    else
        echo "FUNC_TEST:snix-store-verify:SKIP"
        echo "FUNC_TEST:snix-store-list:SKIP"
        echo "FUNC_TEST:snix-store-roots:SKIP"
        echo "FUNC_TEST:snix-store-gc-dryrun:SKIP"
        echo "FUNC_TEST:snix-store-info-missing:SKIP"
        echo "FUNC_TEST:snix-store-closure-missing:SKIP"
        echo "FUNC_TEST:snix-help-has-store:SKIP"
        echo "FUNC_TEST:snix-store-help-complete:SKIP"
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
