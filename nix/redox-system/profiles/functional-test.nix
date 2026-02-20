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

    # ── Store Layer Integration (snix store) ────────────────
    # Full end-to-end test of the local store layer:
    #   1. Create fake store paths on the filesystem
    #   2. Write PathInfo JSON to register them in the database
    #   3. Test closure computation (BFS over references)
    #   4. Add GC roots and verify they protect paths
    #   5. Run garbage collection and verify dead paths are deleted
    #
    # This exercises real filesystem I/O on Redox — not mocks.
    # Uses valid nixbase32 store path hashes throughout.

    if exists -f /bin/snix
        # ── Setup: create 3 fake store paths on disk ──────────
        # app depends on lib, orphan has no dependents
        # Valid nixbase32 hashes (alphabet: 0123456789abcdfghijklmnpqrsvwxyz)
        mkdir -p /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0/bin
        echo '#!/bin/sh' > /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0/bin/testapp
        mkdir -p /nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-testlib-1.0/lib
        echo 'libtest' > /nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-testlib-1.0/lib/libtest.so
        mkdir -p /nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-orphan-1.0/bin
        echo 'orphan' > /nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-orphan-1.0/bin/orphan

        # ── Setup: register PathInfo for each path ────────────
        mkdir -p /nix/var/snix/pathinfo
        mkdir -p /nix/var/snix/gcroots

        # testapp depends on testlib (and itself, as Nix paths commonly do)
        echo '{"storePath":"/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0","narHash":"aaa","narSize":100,"references":["/nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0","/nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-testlib-1.0"],"registrationTime":"2026-01-01T00:00:00Z"}' > /nix/var/snix/pathinfo/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r.json

        # testlib has no dependencies
        echo '{"storePath":"/nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-testlib-1.0","narHash":"bbb","narSize":50,"references":[],"registrationTime":"2026-01-01T00:00:00Z"}' > /nix/var/snix/pathinfo/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s.json

        # orphan has no dependencies and no dependents
        echo '{"storePath":"/nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-orphan-1.0","narHash":"ccc","narSize":25,"references":[],"registrationTime":"2026-01-01T00:00:00Z"}' > /nix/var/snix/pathinfo/3d7lxgskakh8klnz4gydrzk8d6p3rq6r.json

        # ── Test: store list shows all 3 registered paths ─────
        /bin/snix store list > /tmp/sl_out ^> /tmp/sl_err
        if test $? = 0
            grep -q 'testapp' /tmp/sl_out
            if test $? = 0
                grep -q 'testlib' /tmp/sl_out
                if test $? = 0
                    grep -q 'orphan' /tmp/sl_out
                    if test $? = 0
                        grep -q '3 paths' /tmp/sl_out
                        if test $? = 0
                            echo "FUNC_TEST:store-list-3-paths:PASS"
                        else
                            echo "FUNC_TEST:store-list-3-paths:FAIL:count"
                        end
                    else
                        echo "FUNC_TEST:store-list-3-paths:FAIL:no-orphan"
                    end
                else
                    echo "FUNC_TEST:store-list-3-paths:FAIL:no-testlib"
                end
            else
                echo "FUNC_TEST:store-list-3-paths:FAIL:no-testapp"
            end
        else
            echo "FUNC_TEST:store-list-3-paths:FAIL:exit-code"
        end
        rm /tmp/sl_out
        rm /tmp/sl_err

        # ── Test: store info shows metadata for testapp ───────
        /bin/snix store info /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0 > /tmp/si_out ^> /tmp/si_err
        if test $? = 0
            grep -q 'testapp' /tmp/si_out
            if test $? = 0
                grep -q 'References' /tmp/si_out
                if test $? = 0
                    grep -q 'testlib' /tmp/si_out
                    if test $? = 0
                        echo "FUNC_TEST:store-info-metadata:PASS"
                    else
                        echo "FUNC_TEST:store-info-metadata:FAIL:no-ref-to-testlib"
                    end
                else
                    echo "FUNC_TEST:store-info-metadata:FAIL:no-references"
                end
            else
                echo "FUNC_TEST:store-info-metadata:FAIL:no-testapp"
            end
        else
            echo "FUNC_TEST:store-info-metadata:FAIL:exit-code"
        end
        rm /tmp/si_out
        rm /tmp/si_err

        # ── Test: closure of testapp includes testlib ─────────
        /bin/snix store closure /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0 > /tmp/sc_out ^> /tmp/sc_err
        if test $? = 0
            grep -q 'testapp' /tmp/sc_out
            if test $? = 0
                grep -q 'testlib' /tmp/sc_out
                if test $? = 0
                    grep -q '2 paths' /tmp/sc_out
                    if test $? = 0
                        echo "FUNC_TEST:store-closure-deps:PASS"
                    else
                        echo "FUNC_TEST:store-closure-deps:FAIL:count"
                    end
                else
                    echo "FUNC_TEST:store-closure-deps:FAIL:no-testlib"
                end
            else
                echo "FUNC_TEST:store-closure-deps:FAIL:no-testapp"
            end
        else
            echo "FUNC_TEST:store-closure-deps:FAIL:exit-code"
        end
        rm /tmp/sc_out
        rm /tmp/sc_err

        # ── Test: closure does NOT include orphan ─────────────
        /bin/snix store closure /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0 > /tmp/sc2_out ^> /tmp/sc2_err
        grep -q 'orphan' /tmp/sc2_out
        if test $? = 1
            echo "FUNC_TEST:store-closure-excludes-orphan:PASS"
        else
            echo "FUNC_TEST:store-closure-excludes-orphan:FAIL:orphan-in-closure"
        end
        rm /tmp/sc2_out
        rm /tmp/sc2_err

        # ── Test: add a GC root for testapp ───────────────────
        /bin/snix store add-root myapp /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0 > /tmp/ar_out ^> /tmp/ar_err
        if test $? = 0
            echo "FUNC_TEST:store-add-root:PASS"
        else
            echo "FUNC_TEST:store-add-root:FAIL"
        end
        rm /tmp/ar_out
        rm /tmp/ar_err

        # ── Test: roots lists the GC root we just added ───────
        /bin/snix store roots > /tmp/sr_out ^> /tmp/sr_err
        if test $? = 0
            grep -q 'myapp' /tmp/sr_out
            if test $? = 0
                grep -q 'testapp' /tmp/sr_out
                if test $? = 0
                    echo "FUNC_TEST:store-roots-listed:PASS"
                else
                    echo "FUNC_TEST:store-roots-listed:FAIL:no-target"
                end
            else
                echo "FUNC_TEST:store-roots-listed:FAIL:no-myapp"
            end
        else
            echo "FUNC_TEST:store-roots-listed:FAIL:exit-code"
        end
        rm /tmp/sr_out
        rm /tmp/sr_err

        # ── Test: GC dry-run reports orphan as collectible ────
        /bin/snix store gc --dry-run > /tmp/gd_out ^> /tmp/gd_err
        if test $? = 0
            grep -q 'orphan' /tmp/gd_err
            if test $? = 0
                grep -q '1 paths' /tmp/gd_out
                if test $? = 0
                    echo "FUNC_TEST:store-gc-dryrun-orphan:PASS"
                else
                    echo "FUNC_TEST:store-gc-dryrun-orphan:FAIL:count"
                end
            else
                echo "FUNC_TEST:store-gc-dryrun-orphan:FAIL:no-orphan-in-stderr"
            end
        else
            echo "FUNC_TEST:store-gc-dryrun-orphan:FAIL:exit-code"
        end
        rm /tmp/gd_out
        rm /tmp/gd_err

        # ── Test: verify orphan still exists after dry run ────
        if exists -d /nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-orphan-1.0
            echo "FUNC_TEST:store-gc-dryrun-preserves:PASS"
        else
            echo "FUNC_TEST:store-gc-dryrun-preserves:FAIL"
        end

        # ── Test: actual GC deletes orphan ────────────────────
        /bin/snix store gc > /tmp/gc_out ^> /tmp/gc_err
        if test $? = 0
            echo "FUNC_TEST:store-gc-runs:PASS"
        else
            echo "FUNC_TEST:store-gc-runs:FAIL"
        end
        rm /tmp/gc_out
        rm /tmp/gc_err

        # ── Test: orphan is gone from filesystem after GC ─────
        if exists -d /nix/store/3d7lxgskakh8klnz4gydrzk8d6p3rq6r-orphan-1.0
            echo "FUNC_TEST:store-gc-deleted-orphan:FAIL:still-exists"
        else
            echo "FUNC_TEST:store-gc-deleted-orphan:PASS"
        end

        # ── Test: orphan is gone from pathinfo DB after GC ────
        if exists -f /nix/var/snix/pathinfo/3d7lxgskakh8klnz4gydrzk8d6p3rq6r.json
            echo "FUNC_TEST:store-gc-deleted-pathinfo:FAIL:json-still-exists"
        else
            echo "FUNC_TEST:store-gc-deleted-pathinfo:PASS"
        end

        # ── Test: testapp survived GC (protected by root) ─────
        if exists -d /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0
            echo "FUNC_TEST:store-gc-kept-app:PASS"
        else
            echo "FUNC_TEST:store-gc-kept-app:FAIL"
        end

        # ── Test: testlib survived GC (transitive dep of root)─
        if exists -d /nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-testlib-1.0
            echo "FUNC_TEST:store-gc-kept-lib:PASS"
        else
            echo "FUNC_TEST:store-gc-kept-lib:FAIL"
        end

        # ── Test: list now shows 2 paths (orphan gone) ────────
        /bin/snix store list > /tmp/sl2_out ^> /tmp/sl2_err
        if test $? = 0
            grep -q '2 paths' /tmp/sl2_out
            if test $? = 0
                echo "FUNC_TEST:store-list-after-gc:PASS"
            else
                echo "FUNC_TEST:store-list-after-gc:FAIL:count"
            end
        else
            echo "FUNC_TEST:store-list-after-gc:FAIL:exit-code"
        end
        rm /tmp/sl2_out
        rm /tmp/sl2_err

        # ── Test: remove root and GC again → everything gone ──
        /bin/snix store remove-root myapp > /tmp/rr_out ^> /tmp/rr_err
        if test $? = 0
            echo "FUNC_TEST:store-remove-root:PASS"
        else
            echo "FUNC_TEST:store-remove-root:FAIL"
        end
        rm /tmp/rr_out
        rm /tmp/rr_err

        /bin/snix store gc > /tmp/gc2_out ^> /tmp/gc2_err
        if test $? = 0
            echo "FUNC_TEST:store-gc-all:PASS"
        else
            echo "FUNC_TEST:store-gc-all:FAIL"
        end
        rm /tmp/gc2_out
        rm /tmp/gc2_err

        # Everything should be gone now
        if exists -d /nix/store/1b9jydsiygi6jhlz2dxbrxi6b4m1rn4r-testapp-1.0
            echo "FUNC_TEST:store-gc-all-deleted:FAIL:app-still-exists"
        else
            if exists -d /nix/store/2c8kzfrjzhi7jkmz3fxcsyj7c5n2sp5s-testlib-1.0
                echo "FUNC_TEST:store-gc-all-deleted:FAIL:lib-still-exists"
            else
                echo "FUNC_TEST:store-gc-all-deleted:PASS"
            end
        end

        # List should show 0 paths
        /bin/snix store list > /tmp/sl3_out ^> /tmp/sl3_err
        if test $? = 0
            grep -q 'No registered' /tmp/sl3_out
            if test $? = 0
                echo "FUNC_TEST:store-empty-after-gc:PASS"
            else
                echo "FUNC_TEST:store-empty-after-gc:FAIL:not-empty"
            end
        else
            echo "FUNC_TEST:store-empty-after-gc:FAIL:exit-code"
        end
        rm /tmp/sl3_out
        rm /tmp/sl3_err
    else
        echo "FUNC_TEST:store-list-3-paths:SKIP"
        echo "FUNC_TEST:store-info-metadata:SKIP"
        echo "FUNC_TEST:store-closure-deps:SKIP"
        echo "FUNC_TEST:store-closure-excludes-orphan:SKIP"
        echo "FUNC_TEST:store-add-root:SKIP"
        echo "FUNC_TEST:store-roots-listed:SKIP"
        echo "FUNC_TEST:store-gc-dryrun-orphan:SKIP"
        echo "FUNC_TEST:store-gc-dryrun-preserves:SKIP"
        echo "FUNC_TEST:store-gc-runs:SKIP"
        echo "FUNC_TEST:store-gc-deleted-orphan:SKIP"
        echo "FUNC_TEST:store-gc-deleted-pathinfo:SKIP"
        echo "FUNC_TEST:store-gc-kept-app:SKIP"
        echo "FUNC_TEST:store-gc-kept-lib:SKIP"
        echo "FUNC_TEST:store-list-after-gc:SKIP"
        echo "FUNC_TEST:store-remove-root:SKIP"
        echo "FUNC_TEST:store-gc-all:SKIP"
        echo "FUNC_TEST:store-gc-all-deleted:SKIP"
        echo "FUNC_TEST:store-empty-after-gc:SKIP"
    end

    # ── Package Manager (snix install) ───────────────────────────
    # Tests the binary cache bridge: search → install → run → remove.
    # The local cache at /nix/cache/ contains packages built by Nix on
    # the host, NAR-serialized and compressed. snix extracts them to
    # /nix/store/ and links binaries into the profile.

    if exists -f /nix/cache/packages.json

        # Test: snix search lists available packages
        /bin/snix search > /tmp/search_out ^> /tmp/search_err
        if test $? = 0
            grep -q 'packages available' /tmp/search_out
            if test $? = 0
                echo "FUNC_TEST:snix-search:PASS"
            else
                echo "FUNC_TEST:snix-search:FAIL:no-packages-line"
            end
        else
            echo "FUNC_TEST:snix-search:FAIL:exit-code"
        end
        rm /tmp/search_out /tmp/search_err

        # Test: snix search with pattern filters results
        /bin/snix search ripgrep > /tmp/search2_out ^> /tmp/search2_err
        if test $? = 0
            grep -q 'ripgrep' /tmp/search2_out
            if test $? = 0
                echo "FUNC_TEST:snix-search-filter:PASS"
            else
                echo "FUNC_TEST:snix-search-filter:FAIL:no-match"
            end
        else
            echo "FUNC_TEST:snix-search-filter:FAIL:exit-code"
        end
        rm /tmp/search2_out /tmp/search2_err

        # Test: snix install extracts package to /nix/store/ and links into profile
        /bin/snix install ripgrep > /tmp/install_out ^> /tmp/install_err
        if test $? = 0
            echo "FUNC_TEST:snix-install:PASS"
        else
            echo "FUNC_TEST:snix-install:FAIL:exit-code"
            echo "  install stdout:"
            cat /tmp/install_out
            echo "  install stderr:"
            cat /tmp/install_err
        end
        rm /tmp/install_out /tmp/install_err

        # Test: installed binary exists in profile
        if exists -f /nix/var/snix/profiles/default/bin/rg
            echo "FUNC_TEST:snix-install-binary:PASS"
        else
            echo "FUNC_TEST:snix-install-binary:FAIL:not-found"
        end

        # Test: installed binary actually runs
        /nix/var/snix/profiles/default/bin/rg --version > /tmp/rg_out ^> /tmp/rg_err
        if test $? = 0
            grep -q 'ripgrep' /tmp/rg_out
            if test $? = 0
                echo "FUNC_TEST:snix-install-runs:PASS"
            else
                echo "FUNC_TEST:snix-install-runs:FAIL:no-version"
            end
        else
            echo "FUNC_TEST:snix-install-runs:FAIL:exit-code"
        end
        rm /tmp/rg_out /tmp/rg_err

        # Test: snix profile list shows the installed package
        /bin/snix profile list > /tmp/prof_out ^> /tmp/prof_err
        if test $? = 0
            grep -q 'ripgrep' /tmp/prof_out
            if test $? = 0
                echo "FUNC_TEST:snix-profile-list:PASS"
            else
                echo "FUNC_TEST:snix-profile-list:FAIL:no-ripgrep"
            end
        else
            echo "FUNC_TEST:snix-profile-list:FAIL:exit-code"
        end
        rm /tmp/prof_out /tmp/prof_err

        # Test: snix show displays package details
        /bin/snix show ripgrep > /tmp/show_out ^> /tmp/show_err
        if test $? = 0
            grep -q 'In store' /tmp/show_out
            if test $? = 0
                echo "FUNC_TEST:snix-show:PASS"
            else
                echo "FUNC_TEST:snix-show:FAIL:no-info"
            end
        else
            echo "FUNC_TEST:snix-show:FAIL:exit-code"
        end
        rm /tmp/show_out /tmp/show_err

        # Test: snix remove unlinks the package
        /bin/snix remove ripgrep > /tmp/rm_out ^> /tmp/rm_err
        if test $? = 0
            echo "FUNC_TEST:snix-remove:PASS"
        else
            echo "FUNC_TEST:snix-remove:FAIL:exit-code"
        end
        rm /tmp/rm_out /tmp/rm_err

        # Test: binary is gone from profile after remove
        if not exists -f /nix/var/snix/profiles/default/bin/rg
            echo "FUNC_TEST:snix-remove-unlinked:PASS"
        else
            echo "FUNC_TEST:snix-remove-unlinked:FAIL:still-exists"
        end

        # Test: install a second package to prove it's not a one-off
        /bin/snix install fd > /tmp/inst2_out ^> /tmp/inst2_err
        if test $? = 0
            if exists -f /nix/var/snix/profiles/default/bin/fd
                echo "FUNC_TEST:snix-install-second:PASS"
            else
                echo "FUNC_TEST:snix-install-second:FAIL:no-binary"
            end
        else
            echo "FUNC_TEST:snix-install-second:FAIL:exit-code"
        end
        rm /tmp/inst2_out /tmp/inst2_err

    else
        echo "FUNC_TEST:snix-search:SKIP"
        echo "FUNC_TEST:snix-search-filter:SKIP"
        echo "FUNC_TEST:snix-install:SKIP"
        echo "FUNC_TEST:snix-install-binary:SKIP"
        echo "FUNC_TEST:snix-install-runs:SKIP"
        echo "FUNC_TEST:snix-profile-list:SKIP"
        echo "FUNC_TEST:snix-show:SKIP"
        echo "FUNC_TEST:snix-remove:SKIP"
        echo "FUNC_TEST:snix-remove-unlinked:SKIP"
        echo "FUNC_TEST:snix-install-second:SKIP"
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
      ++ opt "ripgrep"
      ++ opt "fd"
      ++ opt "bat"
      ++ opt "hexyl"
      ++ opt "zoxide"
      ++ opt "dust"
      ++ opt "snix";

    shellAliases = {
      ls = "ls --color=auto";
    };

    # Also include ripgrep and fd in the binary cache so the snix
    # install/remove tests can exercise the package manager flow.
    binaryCachePackages =
      lib.optionalAttrs (pkgs ? ripgrep) { ripgrep = pkgs.ripgrep; }
      // lib.optionalAttrs (pkgs ? fd) { fd = pkgs.fd; };
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
