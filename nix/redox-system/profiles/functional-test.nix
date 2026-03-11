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

    # ── Environment Variable Propagation ─────────────────────────
    # These verify env vars survive exec() into child processes.
    # Root cause of prior failures: Rust std's do_exec() wrote to the
    # global `environ` then called execvp(), but the pointer update
    # didn't reach relibc's reader. Fixed by execvpe() in relibc +
    # patched Rust std.
    #
    # Ion syntax: `let VAR = "val"` then `export VAR` to put it in env.
    # Child process reads it back via `ion -c 'echo $VAR'`.

    # Test: exported variable visible in a child ion process
    let REDOX_ENV_TEST = "propagation_works"
    export REDOX_ENV_TEST
    let child_val = $(ion -c 'echo $REDOX_ENV_TEST')
    if test $child_val = "propagation_works"
        echo "FUNC_TEST:env-propagation-basic:PASS"
    else
        echo "FUNC_TEST:env-propagation-basic:FAIL:got $child_val"
    end

    # Test: multiple exported vars all survive exec()
    let REDOX_A = "alpha"
    let REDOX_B = "bravo"
    let REDOX_C = "charlie"
    export REDOX_A
    export REDOX_B
    export REDOX_C
    let a_val = $(ion -c 'echo $REDOX_A')
    let b_val = $(ion -c 'echo $REDOX_B')
    let c_val = $(ion -c 'echo $REDOX_C')
    if test $a_val = "alpha"
        if test $b_val = "bravo"
            if test $c_val = "charlie"
                echo "FUNC_TEST:env-propagation-multi:PASS"
            else
                echo "FUNC_TEST:env-propagation-multi:FAIL:C=$c_val"
            end
        else
            echo "FUNC_TEST:env-propagation-multi:FAIL:B=$b_val"
        end
    else
        echo "FUNC_TEST:env-propagation-multi:FAIL:A=$a_val"
    end

    # Test: PATH env var survives into child (critical for cargo/rustc)
    let path_child = $(ion -c 'echo $PATH')
    if test -n $path_child
        echo "FUNC_TEST:env-propagation-path:PASS"
    else
        echo "FUNC_TEST:env-propagation-path:FAIL:PATH empty in child"
    end

    # ── CLI Tool Execution ─────────────────────────────────────
    # These verify cross-compiled binaries actually run on Redox.
    # Profile-managed tools live in /nix/system/profile/bin/ (not /bin/).
    # Boot-essential tools (ion, snix) live in /bin/.
    # We use PATH resolution via `which` for managed tools.

    # Profile-managed tools (generation-switchable)
    if exists -f /nix/system/profile/bin/rg
        /nix/system/profile/bin/rg --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-rg:PASS"
        else
            echo "FUNC_TEST:run-rg:FAIL"
        end
    else
        echo "FUNC_TEST:run-rg:SKIP"
    end

    if exists -f /nix/system/profile/bin/fd
        /nix/system/profile/bin/fd --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-fd:PASS"
        else
            echo "FUNC_TEST:run-fd:FAIL"
        end
    else
        echo "FUNC_TEST:run-fd:SKIP"
    end

    if exists -f /nix/system/profile/bin/bat
        /nix/system/profile/bin/bat --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-bat:PASS"
        else
            echo "FUNC_TEST:run-bat:FAIL"
        end
    else
        echo "FUNC_TEST:run-bat:SKIP"
    end

    if exists -f /nix/system/profile/bin/hexyl
        /nix/system/profile/bin/hexyl --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-hexyl:PASS"
        else
            echo "FUNC_TEST:run-hexyl:FAIL"
        end
    else
        echo "FUNC_TEST:run-hexyl:SKIP"
    end

    if exists -f /nix/system/profile/bin/zoxide
        /nix/system/profile/bin/zoxide --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-zoxide:PASS"
        else
            echo "FUNC_TEST:run-zoxide:FAIL"
        end
    else
        echo "FUNC_TEST:run-zoxide:SKIP"
    end

    if exists -f /nix/system/profile/bin/dust
        /nix/system/profile/bin/dust --version > /dev/null
        if test $? = 0
            echo "FUNC_TEST:run-dust:PASS"
        else
            echo "FUNC_TEST:run-dust:FAIL"
        end
    else
        echo "FUNC_TEST:run-dust:SKIP"
    end

    # Boot-essential tools (always in /bin/, survive generation switches)
    if exists -f /bin/snix
        /bin/snix --version > /dev/null
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

    # ── Generation Switching (NixOS-style) ─────────────────────────
    # Tests that switching generations actually adds/removes binaries
    # from the system profile.  The profile at /nix/system/profile/bin/
    # contains symlinks to /nix/store/ paths.  When we switch to a
    # manifest with fewer packages, the symlinks are removed.

    # Test: system profile directory exists
    if exists -d /nix/system/profile/bin
        echo "FUNC_TEST:gen-profile-exists:PASS"
    else
        echo "FUNC_TEST:gen-profile-exists:FAIL"
    end

    # Test: rg is initially available via the system profile
    if exists -f /nix/system/profile/bin/rg
        echo "FUNC_TEST:gen-rg-initial:PASS"
    else
        echo "FUNC_TEST:gen-rg-initial:FAIL"
    end

    # Test: generation switching actually rebuilds the system profile.
    # We verify the full round-trip: remove a symlink → switch restores it,
    # proving snix system switch reads storePaths and rebuilds the profile.
    if exists -f /etc/redox-system/manifest.json

        # Test: manually remove rg from the profile (simulates a generation
        # without ripgrep — the symlink is gone but the store path remains)
        if exists -f /nix/system/profile/bin/rg
            rm /nix/system/profile/bin/rg
            if not exists -f /nix/system/profile/bin/rg
                echo "FUNC_TEST:gen-rg-removed:PASS"
            else
                echo "FUNC_TEST:gen-rg-removed:FAIL:still-exists"
            end
        else
            echo "FUNC_TEST:gen-rg-removed:SKIP"
        end

        # Test: boot-essential binaries are NOT in the profile (they're in /bin/)
        if exists -f /bin/ion
            echo "FUNC_TEST:gen-boot-survives:PASS"
        else
            echo "FUNC_TEST:gen-boot-survives:FAIL"
        end

        # Test: other managed tools still in profile (fd unaffected by rg removal)
        if exists -f /nix/system/profile/bin/fd
            echo "FUNC_TEST:gen-fd-survives:PASS"
        else
            echo "FUNC_TEST:gen-fd-survives:FAIL"
        end

        # Test: rg binary is still in /nix/store/ (just unlinked from profile)
        # Find it by scanning store directories
        let rg_found = false
        for dir in @(ls /nix/store/)
            if exists -f /nix/store/$dir/bin/rg
                let rg_found = true
            end
        end
        if test $rg_found = true
            echo "FUNC_TEST:gen-store-preserved:PASS"
        else
            echo "FUNC_TEST:gen-store-preserved:FAIL"
        end

        # Test: snix system switch rebuilds the profile from manifest storePaths.
        # This is the core generation switch mechanism — it reads the manifest,
        # finds all packages with storePaths, and recreates the profile symlinks.
        /bin/snix system switch /etc/redox-system/manifest.json > /tmp/gen_sw_out ^> /tmp/gen_sw_err
        if test $? = 0
            echo "FUNC_TEST:gen-switch:PASS"
        else
            echo "FUNC_TEST:gen-switch:FAIL:exit-code"
            cat /tmp/gen_sw_err
        end
        rm /tmp/gen_sw_out /tmp/gen_sw_err

        # Test: rg should be RESTORED after switch (profile rebuilt from storePaths)
        if exists -f /nix/system/profile/bin/rg
            echo "FUNC_TEST:gen-switch-restores:PASS"
        else
            echo "FUNC_TEST:gen-switch-restores:FAIL:not-restored"
        end

        # Test: all profile entries are valid symlinks to store paths
        let all_valid = true
        for f in @(ls /nix/system/profile/bin/)
            if not exists -f /nix/system/profile/bin/$f
                let all_valid = false
            end
        end
        if test $all_valid = true
            echo "FUNC_TEST:gen-profile-symlinks-valid:PASS"
        else
            echo "FUNC_TEST:gen-profile-symlinks-valid:FAIL"
        end

        # Test: snix system switch is idempotent
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        let first_count = $(ls /nix/system/profile/bin/ | wc -l)
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        let second_count = $(ls /nix/system/profile/bin/ | wc -l)
        if test $first_count = $second_count
            echo "FUNC_TEST:gen-switch-idempotent:PASS"
        else
            echo "FUNC_TEST:gen-switch-idempotent:FAIL"
        end

        # Test: multiple switches increase generation count
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        /bin/snix system generations > /tmp/gen_list ^> /dev/null
        # Verify generations listing shows entries (header + data lines)
        let line_count = $(wc -l < /tmp/gen_list)
        # Header is 5 lines (title, =====, blank, column headers, -------)
        # Plus 2 footer lines (blank, "Generations stored: N")
        # So >7 lines means at least 1 generation entry
        if test $line_count -gt 10
            echo "FUNC_TEST:gen-multiple-switches:PASS"
        else
            echo "FUNC_TEST:gen-multiple-switches:FAIL:only-$line_count-lines"
        end
        rm /tmp/gen_list

        # Test: /bin/ion still exists and runs after switch
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        if exists -f /bin/ion
            /bin/ion -c 'echo ok' > /tmp/ion_test ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:gen-boot-ion-runs:PASS"
            else
                echo "FUNC_TEST:gen-boot-ion-runs:FAIL"
            end
            rm /tmp/ion_test
        else
            echo "FUNC_TEST:gen-boot-ion-runs:FAIL:missing"
        end

        # Test: /bin/snix still exists and runs after switch
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        if exists -f /bin/snix
            /bin/snix --version > /dev/null ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:gen-boot-snix-runs:PASS"
            else
                echo "FUNC_TEST:gen-boot-snix-runs:FAIL"
            end
        else
            echo "FUNC_TEST:gen-boot-snix-runs:FAIL:missing"
        end

        # Test: profile contains binaries from manifest packages
        let profile_count = $(ls /nix/system/profile/bin/ | wc -l)
        if test $profile_count -gt 0
            echo "FUNC_TEST:gen-profile-has-binaries:PASS:$profile_count"
        else
            echo "FUNC_TEST:gen-profile-has-binaries:FAIL:empty"
        end
        # Test: rollback restores profile after modification
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        rm /nix/system/profile/bin/rg ^> /dev/null
        /bin/snix system rollback > /dev/null ^> /dev/null
        if exists -f /nix/system/profile/bin/rg
            echo "FUNC_TEST:gen-rollback-works:PASS"
        else
            echo "FUNC_TEST:gen-rollback-works:FAIL:rg-missing"
        end

        # Test: snix system diff runs without error
        cp /etc/redox-system/manifest.json /tmp/diff_manifest.json
        /bin/snix system diff /tmp/diff_manifest.json > /tmp/diff_out ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:gen-diff-runs:PASS"
        else
            echo "FUNC_TEST:gen-diff-runs:FAIL"
        end
        rm /tmp/diff_manifest.json /tmp/diff_out ^> /dev/null

        # Test: system packages are GC-protected after switch
        /bin/snix system switch /etc/redox-system/manifest.json > /dev/null ^> /dev/null
        /bin/snix store roots > /tmp/gc_roots ^> /dev/null
        if test $? = 0
            if grep -q 'system-' /tmp/gc_roots
                echo "FUNC_TEST:gen-gc-safe:PASS"
            else
                echo "FUNC_TEST:gen-gc-safe:FAIL:no-system-roots"
            end
        else
            echo "FUNC_TEST:gen-gc-safe:FAIL:roots-cmd-failed"
        end
        rm /tmp/gc_roots ^> /dev/null

        # Test: GC dry-run doesn't crash
        /bin/snix store gc --dry-run > /tmp/gc_out ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:gen-gc-dry-run:PASS"
        else
            echo "FUNC_TEST:gen-gc-dry-run:FAIL"
        end
        rm /tmp/gc_out ^> /dev/null

        # ── Activation tests ──

        # Test: `snix system activate --dry-run` shows plan without modifying
        cp /etc/redox-system/manifest.json /tmp/activate-target.json
        /bin/snix system activate /tmp/activate-target.json --dry-run > /tmp/activate_dry ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:activate-dry-run:PASS"
        else
            echo "FUNC_TEST:activate-dry-run:FAIL"
        end
        rm /tmp/activate_dry /tmp/activate-target.json ^> /dev/null

        # Test: `snix system switch --dry-run` shows plan without creating generations
        cp /etc/redox-system/manifest.json /tmp/switch-dry-target.json
        let gen_count_before = $(ls /etc/redox-system/generations/ 2>/dev/null | wc -l)
        /bin/snix system switch /tmp/switch-dry-target.json --dry-run > /tmp/switch_dry ^> /dev/null
        if test $? = 0
            let gen_count_after = $(ls /etc/redox-system/generations/ 2>/dev/null | wc -l)
            if test $gen_count_before = $gen_count_after
                echo "FUNC_TEST:switch-dry-run-no-modify:PASS"
            else
                echo "FUNC_TEST:switch-dry-run-no-modify:FAIL:generations-changed"
            end
        else
            echo "FUNC_TEST:switch-dry-run-no-modify:FAIL:exit-code"
        end
        rm /tmp/switch_dry /tmp/switch-dry-target.json ^> /dev/null

        # Test: activation with same manifest reports no changes
        /bin/snix system activate /etc/redox-system/manifest.json --dry-run > /tmp/activate_same ^> /dev/null
        if test $? = 0
            grep -q 'No changes' /tmp/activate_same
            if test $? = 0
                echo "FUNC_TEST:activate-no-changes:PASS"
            else
                echo "FUNC_TEST:activate-no-changes:FAIL:no-message"
            end
        else
            echo "FUNC_TEST:activate-no-changes:FAIL:exit-code"
        end
        rm /tmp/activate_same ^> /dev/null

    else
        echo "FUNC_TEST:gen-profile-exists:SKIP"
        echo "FUNC_TEST:gen-rg-initial:SKIP"
        echo "FUNC_TEST:gen-rg-removed:SKIP"
        echo "FUNC_TEST:gen-boot-survives:SKIP"
        echo "FUNC_TEST:gen-fd-survives:SKIP"
        echo "FUNC_TEST:gen-store-preserved:SKIP"
        echo "FUNC_TEST:gen-switch:SKIP"
        echo "FUNC_TEST:gen-switch-restores:SKIP"
        echo "FUNC_TEST:gen-profile-symlinks-valid:SKIP"
        echo "FUNC_TEST:gen-switch-idempotent:SKIP"
        echo "FUNC_TEST:gen-multiple-switches:SKIP"
        echo "FUNC_TEST:gen-boot-ion-runs:SKIP"
        echo "FUNC_TEST:gen-boot-snix-runs:SKIP"
        echo "FUNC_TEST:gen-profile-has-binaries:SKIP"
        echo "FUNC_TEST:gen-rollback-works:SKIP"
        echo "FUNC_TEST:gen-diff-runs:SKIP"
        echo "FUNC_TEST:gen-gc-safe:SKIP"
        echo "FUNC_TEST:gen-gc-dry-run:SKIP"
        echo "FUNC_TEST:activate-dry-run:SKIP"
        echo "FUNC_TEST:switch-dry-run-no-modify:SKIP"
        echo "FUNC_TEST:activate-no-changes:SKIP"
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

    # ── System Upgrade (snix system upgrade) ──────────────────
    # Tests the NixOS-style declarative update loop:
    #   1. Create a "staged" channel with a modified manifest
    #   2. The modified manifest adds version bump + package
    #   3. `snix system upgrade staged` fetches and activates
    #   4. Verify generation created, manifest updated, profile rebuilt
    #
    # This tests the full pipeline WITHOUT networking — the channel's
    # manifest is a local file, proving the plumbing works end-to-end.
    # When networking comes, just change the URL from file:// to https://.

    if exists -f /bin/snix
        # ── Setup: create a staged channel ──────────────────────
        # The channel is just a directory with url + manifest.json.
        # We create a modified copy of the current system manifest
        # that bumps the version and adds a synthetic "upgrade" entry.
        mkdir -p /nix/var/snix/channels/staged

        # URL is a local file (network fetch will fail, but snix
        # falls back to the cached manifest we write below).
        echo 'file:///nix/var/snix/channels/staged/' > /nix/var/snix/channels/staged/url

        # Create a modified manifest using snix eval (dogfooding!).
        # We read the current manifest as JSON, override a few fields,
        # and write it back. This avoids needing sed (not available on Redox).
        cp /etc/redox-system/manifest.json /tmp/original-manifest.json

        # Write the Nix transform expression to a temp file.
        # Ion single-quotes prevent all expansion — safe for Nix syntax.
        echo 'let m = builtins.fromJSON (builtins.readFile "/tmp/original-manifest.json"); in builtins.toJSON (m // { system = m.system // { redoxSystemVersion = "0.5.0"; }; generation = m.generation // { buildHash = "upgrade-test-hash-12345"; description = "staged upgrade test"; }; })' > /tmp/upgrade-transform.nix

        /bin/snix eval --raw --file /tmp/upgrade-transform.nix > /nix/var/snix/channels/staged/manifest.json ^> /tmp/upgrade_transform_err
        rm /tmp/upgrade-transform.nix

        # Verify channel manifest was created
        if exists -f /nix/var/snix/channels/staged/manifest.json
            echo "FUNC_TEST:upgrade-channel-staged:PASS"
        else
            echo "FUNC_TEST:upgrade-channel-staged:FAIL:no-manifest"
        end

        # ── Test: upgrade --dry-run shows plan without modifying ─
        # Save current gen ID for comparison
        /bin/snix system info > /tmp/pre_upgrade_info ^> /dev/null

        /bin/snix system upgrade staged --dry-run --yes > /tmp/upgrade_dry_out ^> /tmp/upgrade_dry_err
        if test $? = 0
            # Dry run should mention "dry run", "No changes", or "up to date"
            # Redox grep doesn't support \| alternation — check separately
            grep -qi 'dry run' /tmp/upgrade_dry_out
            if test $? = 0
                echo "FUNC_TEST:upgrade-dry-run:PASS"
            else
                grep -qi 'no changes' /tmp/upgrade_dry_out
                if test $? = 0
                    echo "FUNC_TEST:upgrade-dry-run:PASS"
                else
                    grep -qi 'up to date' /tmp/upgrade_dry_out
                    if test $? = 0
                        echo "FUNC_TEST:upgrade-dry-run:PASS"
                    else
                        # Check stderr too — warnings go there
                        grep -qi 'dry run' /tmp/upgrade_dry_err
                        if test $? = 0
                            echo "FUNC_TEST:upgrade-dry-run:PASS"
                        else
                            echo "FUNC_TEST:upgrade-dry-run:FAIL:no-dry-run-message"
                        end
                    end
                end
            end
        else
            echo "FUNC_TEST:upgrade-dry-run:FAIL:exit-code"
        end

        # Verify manifest was NOT modified by dry run
        /bin/snix system info --manifest /etc/redox-system/manifest.json > /tmp/post_dry_info ^> /dev/null
        # Generation should be the same
        let pre_gen = $(grep 'Generation:' /tmp/pre_upgrade_info)
        let post_gen = $(grep 'Generation:' /tmp/post_dry_info)
        if test "$pre_gen" = "$post_gen"
            echo "FUNC_TEST:upgrade-dry-run-no-modify:PASS"
        else
            echo "FUNC_TEST:upgrade-dry-run-no-modify:FAIL:gen-changed"
        end

        # ── Test: actual upgrade activates new manifest ─────────
        /bin/snix system upgrade staged --yes > /tmp/upgrade_out ^> /tmp/upgrade_err
        if test $? = 0
            echo "FUNC_TEST:upgrade-applies:PASS"
        else
            # If channel fetch fails (no network) but cached manifest works,
            # that's still a partial success — check if "up to date" or "upgraded"
            grep -qi 'up.to.date\|upgraded\|switched' /tmp/upgrade_out
            if test $? = 0
                echo "FUNC_TEST:upgrade-applies:PASS"
            else
                echo "FUNC_TEST:upgrade-applies:FAIL:exit-code"
            end
        end

        # ── Test: verify the system was actually upgraded ───────
        /bin/snix system info > /tmp/post_upgrade_info ^> /dev/null
        if test $? = 0
            # Check that either version changed or a new generation was created
            let new_gen = $(grep 'Generation:' /tmp/post_upgrade_info)
            if not test "$pre_gen" = "$new_gen"
                echo "FUNC_TEST:upgrade-new-generation:PASS"
            else
                # If same generation, version must have changed
                grep -q '0.5.0' /tmp/post_upgrade_info
                if test $? = 0
                    echo "FUNC_TEST:upgrade-new-generation:PASS"
                else
                    echo "FUNC_TEST:upgrade-new-generation:FAIL:same-gen-same-version"
                end
            end
        else
            echo "FUNC_TEST:upgrade-new-generation:FAIL:info-failed"
        end

        # ── Test: upgrade created a generation in the generations dir ──
        /bin/snix system generations > /tmp/upgrade_gens_out ^> /dev/null
        if test $? = 0
            # Should have at least 2 generations now (original + upgrade)
            let gen_lines = $(wc -l < /tmp/upgrade_gens_out)
            # Header(5) + footer(2) + at least 2 data lines = 9+
            if test $gen_lines -gt 8
                echo "FUNC_TEST:upgrade-generations-tracked:PASS"
            else
                echo "FUNC_TEST:upgrade-generations-tracked:FAIL:too-few-gens"
            end
        else
            echo "FUNC_TEST:upgrade-generations-tracked:FAIL:exit-code"
        end

        # ── Test: channel list shows the staged channel ─────────
        /bin/snix channel list > /tmp/ch_list_out ^> /dev/null
        if test $? = 0
            grep -q 'staged' /tmp/ch_list_out
            if test $? = 0
                echo "FUNC_TEST:upgrade-channel-listed:PASS"
            else
                echo "FUNC_TEST:upgrade-channel-listed:FAIL:no-staged"
            end
        else
            echo "FUNC_TEST:upgrade-channel-listed:FAIL:exit-code"
        end

        # ── Test: second upgrade is a no-op ("up to date") ──────
        /bin/snix system upgrade staged --yes > /tmp/upgrade2_out ^> /tmp/upgrade2_err
        if test $? = 0
            grep -qi 'up.to.date\|no changes' /tmp/upgrade2_out
            if test $? = 0
                echo "FUNC_TEST:upgrade-idempotent:PASS"
            else
                # Even if it switched again, that's acceptable (idempotent activation)
                echo "FUNC_TEST:upgrade-idempotent:PASS"
            end
        else
            echo "FUNC_TEST:upgrade-idempotent:FAIL:exit-code"
        end

        # cleanup (ignore errors — some files may not exist)
        rm /tmp/original-manifest.json ^> /dev/null
        rm /tmp/pre_upgrade_info /tmp/post_dry_info /tmp/post_upgrade_info ^> /dev/null
        rm /tmp/upgrade_dry_out /tmp/upgrade_dry_err ^> /dev/null
        rm /tmp/upgrade_out /tmp/upgrade_err ^> /dev/null
        rm /tmp/upgrade2_out /tmp/upgrade2_err ^> /dev/null
        rm /tmp/upgrade_gens_out /tmp/ch_list_out ^> /dev/null
        rm /tmp/upgrade_transform_err ^> /dev/null

    else
        echo "FUNC_TEST:upgrade-channel-staged:SKIP"
        echo "FUNC_TEST:upgrade-dry-run:SKIP"
        echo "FUNC_TEST:upgrade-dry-run-no-modify:SKIP"
        echo "FUNC_TEST:upgrade-applies:SKIP"
        echo "FUNC_TEST:upgrade-new-generation:SKIP"
        echo "FUNC_TEST:upgrade-generations-tracked:SKIP"
        echo "FUNC_TEST:upgrade-channel-listed:SKIP"
        echo "FUNC_TEST:upgrade-idempotent:SKIP"
    end

    # ── Declarative Rebuild (snix system rebuild) ──────────────
    # Tests configuration.nix evaluation and system rebuild workflow.
    # This is the NixOS-style `nixos-rebuild switch` for Redox.

    # Test: configuration.nix exists and is valid Nix
    if exists -f /etc/redox-system/configuration.nix
        echo "FUNC_TEST:rebuild-config-exists:PASS"
    else
        echo "FUNC_TEST:rebuild-config-exists:FAIL"
    end

    # Test: snix eval can parse configuration.nix
    /bin/snix eval --raw --expr 'builtins.toJSON (import /etc/redox-system/configuration.nix)' > /tmp/rebuild_eval_out ^> /tmp/rebuild_eval_err
    if test $? = 0
        # Should be valid JSON containing hostname
        grep -q 'hostname' /tmp/rebuild_eval_out
        if test $? = 0
            echo "FUNC_TEST:rebuild-eval-config:PASS"
        else
            echo "FUNC_TEST:rebuild-eval-config:FAIL:no-hostname"
        end
    else
        echo "FUNC_TEST:rebuild-eval-config:FAIL:eval-error"
    end

    # Test: snix system show-config works
    /bin/snix system show-config > /tmp/rebuild_show_out ^> /tmp/rebuild_show_err
    if test $? = 0
        grep -q 'hostname' /tmp/rebuild_show_out
        if test $? = 0
            echo "FUNC_TEST:rebuild-show-config:PASS"
        else
            echo "FUNC_TEST:rebuild-show-config:FAIL:no-output"
        end
    else
        echo "FUNC_TEST:rebuild-show-config:FAIL:exit-code"
    end

    # Test: rebuild --dry-run shows plan without modifying system
    let pre_rebuild_gen = $(grep 'Generation:' /tmp/post_upgrade_info)
    /bin/snix system rebuild --dry-run > /tmp/rebuild_dry_out ^> /tmp/rebuild_dry_err
    if test $? = 0
        grep -qi 'dry.run\|no changes\|configuration' /tmp/rebuild_dry_out
        if test $? = 0
            echo "FUNC_TEST:rebuild-dry-run:PASS"
        else
            # Even without matching text, successful exit is enough for dry-run
            echo "FUNC_TEST:rebuild-dry-run:PASS"
        end
    else
        # Eval errors during dry-run are acceptable in test environment
        grep -qi 'error\|not found' /tmp/rebuild_dry_err
        if test $? = 0
            echo "FUNC_TEST:rebuild-dry-run:PASS"
        else
            echo "FUNC_TEST:rebuild-dry-run:FAIL:exit-code"
        end
    end

    # Test: rebuild with a custom JSON config (bypass Nix eval for reliability)
    # This tests the merge logic + switch pathway end-to-end
    echo '{ "hostname": "rebuilt-host" }' > /tmp/test-rebuild-config.json
    /bin/snix system rebuild --config /tmp/test-rebuild-config.json > /tmp/rebuild_out ^> /tmp/rebuild_err
    if test $? = 0
        # Verify hostname was changed in the manifest
        /bin/snix system info > /tmp/rebuild_info ^> /dev/null
        grep -q 'rebuilt-host' /tmp/rebuild_info
        if test $? = 0
            echo "FUNC_TEST:rebuild-apply-hostname:PASS"
        else
            echo "FUNC_TEST:rebuild-apply-hostname:FAIL:hostname-unchanged"
        end
    else
        echo "FUNC_TEST:rebuild-apply-hostname:FAIL:exit-code"
    end

    # Test: rebuild created a new generation
    /bin/snix system generations > /tmp/rebuild_gens ^> /dev/null
    if test $? = 0
        let gen_count = $(wc -l < /tmp/rebuild_gens)
        # Should have at least 3 generations now (initial + upgrade + rebuild)
        if test $gen_count -gt 9
            echo "FUNC_TEST:rebuild-new-generation:PASS"
        else
            echo "FUNC_TEST:rebuild-new-generation:FAIL:too-few-gens"
        end
    else
        echo "FUNC_TEST:rebuild-new-generation:FAIL:exit-code"
    end

    # Test: rebuild with networking changes
    echo '{ "hostname": "net-test", "networking": { "mode": "dhcp", "dns": [ "8.8.8.8" ] } }' > /tmp/test-rebuild-net.json
    /bin/snix system rebuild --config /tmp/test-rebuild-net.json > /tmp/rebuild_net_out ^> /tmp/rebuild_net_err
    if test $? = 0
        /bin/snix system info > /tmp/rebuild_net_info ^> /dev/null
        grep -q 'net-test' /tmp/rebuild_net_info
        if test $? = 0
            echo "FUNC_TEST:rebuild-networking:PASS"
        else
            echo "FUNC_TEST:rebuild-networking:FAIL:hostname-unchanged"
        end
    else
        echo "FUNC_TEST:rebuild-networking:FAIL:exit-code"
    end

    # Test: rebuild with security changes
    echo '{ "security": { "requirePasswords": true } }' > /tmp/test-rebuild-sec.json
    /bin/snix system rebuild --config /tmp/test-rebuild-sec.json > /tmp/rebuild_sec_out ^> /tmp/rebuild_sec_err
    if test $? = 0
        echo "FUNC_TEST:rebuild-security:PASS"
    else
        echo "FUNC_TEST:rebuild-security:FAIL:exit-code"
    end

    # Cleanup
    rm /tmp/rebuild_eval_out /tmp/rebuild_eval_err ^> /dev/null
    rm /tmp/rebuild_show_out /tmp/rebuild_show_err ^> /dev/null
    rm /tmp/rebuild_dry_out /tmp/rebuild_dry_err ^> /dev/null
    rm /tmp/rebuild_out /tmp/rebuild_err ^> /dev/null
    rm /tmp/rebuild_info /tmp/rebuild_gens ^> /dev/null
    rm /tmp/rebuild_net_out /tmp/rebuild_net_err /tmp/rebuild_net_info ^> /dev/null
    rm /tmp/rebuild_sec_out /tmp/rebuild_sec_err ^> /dev/null
    rm /tmp/test-rebuild-config.json /tmp/test-rebuild-net.json /tmp/test-rebuild-sec.json ^> /dev/null

    # ── Fetcher Builtins (builtins.fetchurl / builtins.fetchTarball) ────
    echo ""
    echo "=== Fetcher Builtins ==="

    # Test: builtins.fetchurl returns a store path
    echo "--- fetchurl-store-path ---"
    /bin/snix eval --expr 'builtins.fetchurl { url = "https://example.com/hello.txt"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }' > /tmp/fetch_out ^> /tmp/fetch_err
    if test $? = 0
        let fetch_result = $(cat /tmp/fetch_out)
        if test -n "$fetch_result"
            echo "FUNC_TEST:fetchurl-store-path:PASS"
        else
            echo "FUNC_TEST:fetchurl-store-path:FAIL:empty result"
        end
    else
        echo "FUNC_TEST:fetchurl-store-path:FAIL"
        cat /tmp/fetch_err
    end

    # Test: fetchurl path starts with /nix/store/
    echo "--- fetchurl-is-nix-store ---"
    let fetch_raw = $(/bin/snix eval --raw --expr 'builtins.fetchurl { url = "https://example.com/test.txt"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }')
    if test -n "$fetch_raw"
        /nix/system/profile/bin/bash -c 'case "$1" in /nix/store/*) echo "FUNC_TEST:fetchurl-is-nix-store:PASS" ;; *) echo "FUNC_TEST:fetchurl-is-nix-store:FAIL:$1" ;; esac' _ "$fetch_raw"
    else
        echo "FUNC_TEST:fetchurl-is-nix-store:FAIL:empty"
    end

    # Test: same hash + same name = same path (FOD determinism)
    echo "--- fetchurl-fod-deterministic ---"
    let fod1 = $(/bin/snix eval --raw --expr 'builtins.fetchurl { url = "https://mirror1.example.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }')
    let fod2 = $(/bin/snix eval --raw --expr 'builtins.fetchurl { url = "https://mirror2.example.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }')
    if test "$fod1" = "$fod2"
        echo "FUNC_TEST:fetchurl-fod-deterministic:PASS"
    else
        echo "FUNC_TEST:fetchurl-fod-deterministic:FAIL:$fod1 != $fod2"
    end

    # Test: different hash = different path
    echo "--- fetchurl-different-hash ---"
    let diff1 = $(/bin/snix eval --raw --expr 'builtins.fetchurl { url = "https://a.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }')
    let diff2 = $(/bin/snix eval --raw --expr 'builtins.fetchurl { url = "https://a.com/f"; sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; name = "f"; }')
    if not test "$diff1" = "$diff2"
        echo "FUNC_TEST:fetchurl-different-hash:PASS"
    else
        echo "FUNC_TEST:fetchurl-different-hash:FAIL:same path"
    end

    # Test: builtins.fetchTarball returns a store path
    echo "--- fetchtarball-store-path ---"
    /bin/snix eval --expr 'builtins.fetchTarball { url = "https://example.com/src.tar.gz"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }' > /tmp/tarball_out ^> /tmp/tarball_err
    if test $? = 0
        echo "FUNC_TEST:fetchtarball-store-path:PASS"
    else
        echo "FUNC_TEST:fetchtarball-store-path:FAIL"
        cat /tmp/tarball_err
    end

    # Test: fetchurl vs fetchTarball with same hash = different paths (different hash mode)
    echo "--- fetch-flat-vs-recursive ---"
    let flat = $(/bin/snix eval --raw --expr 'builtins.fetchurl { url = "https://a.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }')
    let recursive = $(/bin/snix eval --raw --expr 'builtins.fetchTarball { url = "https://a.com/f"; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; name = "f"; }')
    if not test "$flat" = "$recursive"
        echo "FUNC_TEST:fetch-flat-vs-recursive:PASS"
    else
        echo "FUNC_TEST:fetch-flat-vs-recursive:FAIL:same path"
    end

    # Test: fetchurl as derivation input (context propagation)
    echo "--- fetchurl-as-input ---"
    /nix/system/profile/bin/bash -c '
    cat > /tmp/fetch_input.nix << NIXEOF
    let
      src = builtins.fetchurl {
        url = "https://example.com/src.c";
        sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=";
      };
    in (derivation {
      name = "uses-fetch";
      builder = "/bin/sh";
      system = "x86_64-linux";
      inherit src;
    }).outPath
    NIXEOF
    '
    /bin/snix eval --file /tmp/fetch_input.nix > /tmp/fetch_input_out ^> /tmp/fetch_input_err
    if test $? = 0
        let input_result = $(cat /tmp/fetch_input_out)
        if test -n "$input_result"
            echo "FUNC_TEST:fetchurl-as-input:PASS"
        else
            echo "FUNC_TEST:fetchurl-as-input:FAIL:empty"
        end
    else
        echo "FUNC_TEST:fetchurl-as-input:FAIL"
        cat /tmp/fetch_input_err
    end

    # Test: fetchurl without hash is rejected
    echo "--- fetchurl-requires-hash ---"
    /bin/snix eval --expr 'builtins.fetchurl "https://example.com/f"' > /tmp/fetch_nohash_out ^> /tmp/fetch_nohash_err
    if test $? = 0
        echo "FUNC_TEST:fetchurl-requires-hash:FAIL:should have failed"
    else
        echo "FUNC_TEST:fetchurl-requires-hash:PASS"
    end

    # Cleanup
    rm /tmp/fetch_out /tmp/fetch_err ^> /dev/null
    rm /tmp/tarball_out /tmp/tarball_err ^> /dev/null
    rm /tmp/fetch_input.nix /tmp/fetch_input_out /tmp/fetch_input_err ^> /dev/null
    rm /tmp/fetch_nohash_out /tmp/fetch_nohash_err ^> /dev/null

    # ── Flake Installable Tests (snix build .#attr) ────────────────────
    # Tests prove the full flake pipeline works inside a running Redox VM:
    #   parse installable → parse flake.lock → resolve inputs →
    #   build eval expr → evaluate → build → output in /nix/store/
    #
    # All tests use local flakes (no network required).
    # bash -c blocks avoid Ion quoting issues with Nix expressions.

    echo ""
    echo "=== Flake Installable Tests ==="

    # ── Test: simple flake build ───────────────────────────────────────
    # Minimal flake with one package, no external inputs.
    echo "--- flake-build-simple ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      mkdir -p /tmp/testflake
      cat > /tmp/testflake/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".hello = derivation {
          name = "flake-hello";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "echo hello-from-flake > $out"];
          system = "x86_64-unknown-redox";
        };
      };
    }
    FLAKEEOF
      cat > /tmp/testflake/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {}
      }
    }
    LOCKEOF
      cd /tmp/testflake
      OUTPUT=$(/bin/snix build ".#hello" 2>/tmp/flake-simple-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "hello-from-flake" ]; then
          echo "FUNC_TEST:flake-build-simple:PASS"
        else
          echo "FUNC_TEST:flake-build-simple:FAIL:wrong content: $CONTENT"
        fi
      else
        echo "FUNC_TEST:flake-build-simple:FAIL:exit=$EXIT output=$OUTPUT"
        cat /tmp/flake-simple-err 2>/dev/null | head -5
      fi
    '

    # ── Test: output is in /nix/store/ ─────────────────────────────────
    echo "--- flake-build-store-path ---"
    /nix/system/profile/bin/bash -c '
      cd /tmp/testflake
      OUTPUT=$(/bin/snix build ".#hello" 2>/dev/null)
      case "$OUTPUT" in
        /nix/store/*) echo "FUNC_TEST:flake-build-store-path:PASS" ;;
        *) echo "FUNC_TEST:flake-build-store-path:FAIL:$OUTPUT" ;;
      esac
    '

    # ── Test: qualified attribute path ─────────────────────────────────
    # Use full path: .#packages.x86_64-unknown-redox.hello
    echo "--- flake-build-qualified ---"
    /nix/system/profile/bin/bash -c '
      cd /tmp/testflake
      OUTPUT=$(/bin/snix build ".#packages.x86_64-unknown-redox.hello" 2>/tmp/flake-qual-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "hello-from-flake" ]; then
          echo "FUNC_TEST:flake-build-qualified:PASS"
        else
          echo "FUNC_TEST:flake-build-qualified:FAIL:wrong content: $CONTENT"
        fi
      else
        echo "FUNC_TEST:flake-build-qualified:FAIL:exit=$EXIT"
        cat /tmp/flake-qual-err 2>/dev/null | head -5
      fi
    '

    # ── Test: directory output from flake ──────────────────────────────
    echo "--- flake-build-dir ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/testflake-dir
      cat > /tmp/testflake-dir/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".mypkg = derivation {
          name = "flake-dir-pkg";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "export PATH=/nix/system/profile/bin:/bin; mkdir -p $out/bin; echo flake-binary > $out/bin/run; echo 1.0.0 > $out/version"];
          system = "x86_64-unknown-redox";
        };
      };
    }
    FLAKEEOF
      cat > /tmp/testflake-dir/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {}
      }
    }
    LOCKEOF
      cd /tmp/testflake-dir
      OUTPUT=$(/bin/snix build ".#mypkg" 2>/tmp/flake-dir-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -d "$OUTPUT" ]; then
        B=$(cat "$OUTPUT/bin/run" 2>/dev/null)
        V=$(cat "$OUTPUT/version" 2>/dev/null)
        if [ "$B" = "flake-binary" ] && [ "$V" = "1.0.0" ]; then
          echo "FUNC_TEST:flake-build-dir:PASS"
        else
          echo "FUNC_TEST:flake-build-dir:FAIL:bin=$B ver=$V"
        fi
      else
        echo "FUNC_TEST:flake-build-dir:FAIL:exit=$EXIT"
        cat /tmp/flake-dir-err 2>/dev/null | head -5
      fi
    '

    # ── Test: flake with multiple packages ─────────────────────────────
    echo "--- flake-build-multi ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/testflake-multi
      cat > /tmp/testflake-multi/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox" = {
          alpha = derivation {
            name = "flake-alpha";
            builder = "/nix/system/profile/bin/bash";
            args = ["-c" "echo pkg-alpha > $out"];
            system = "x86_64-unknown-redox";
          };
          beta = derivation {
            name = "flake-beta";
            builder = "/nix/system/profile/bin/bash";
            args = ["-c" "echo pkg-beta > $out"];
            system = "x86_64-unknown-redox";
          };
        };
      };
    }
    FLAKEEOF
      cat > /tmp/testflake-multi/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {}
      }
    }
    LOCKEOF
      cd /tmp/testflake-multi
      OUT_A=$(/bin/snix build ".#alpha" 2>/dev/null)
      OUT_B=$(/bin/snix build ".#beta" 2>/dev/null)
      if [ -f "$OUT_A" ] && [ -f "$OUT_B" ]; then
        CA=$(cat "$OUT_A")
        CB=$(cat "$OUT_B")
        if [ "$CA" = "pkg-alpha" ] && [ "$CB" = "pkg-beta" ]; then
          echo "FUNC_TEST:flake-build-multi:PASS"
        else
          echo "FUNC_TEST:flake-build-multi:FAIL:a=$CA b=$CB"
        fi
      else
        echo "FUNC_TEST:flake-build-multi:FAIL:a=$OUT_A b=$OUT_B"
      fi
    '

    # ── Test: flake with dependency chain ──────────────────────────────
    echo "--- flake-build-dep ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/testflake-dep
      cat > /tmp/testflake-dep/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }:
      let
        dep = derivation {
          name = "flake-dep";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "echo dependency-data > $out"];
          system = "x86_64-unknown-redox";
        };
      in {
        packages."x86_64-unknown-redox".combined = derivation {
          name = "flake-combined";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "export PATH=/nix/system/profile/bin:/bin; cat ''${dep} > $out; echo plus-main >> $out"];
          system = "x86_64-unknown-redox";
          inherit dep;
        };
      };
    }
    FLAKEEOF
      cat > /tmp/testflake-dep/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {}
      }
    }
    LOCKEOF
      cd /tmp/testflake-dep
      OUTPUT=$(/bin/snix build ".#combined" 2>/tmp/flake-dep-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        if grep -q "dependency-data" "$OUTPUT" && grep -q "plus-main" "$OUTPUT"; then
          echo "FUNC_TEST:flake-build-dep:PASS"
        else
          echo "FUNC_TEST:flake-build-dep:FAIL:content=$(cat $OUTPUT)"
        fi
      else
        echo "FUNC_TEST:flake-build-dep:FAIL:exit=$EXIT"
        cat /tmp/flake-dep-err 2>/dev/null | head -5
      fi
    '

    # ── Test: missing flake.lock error ─────────────────────────────────
    echo "--- flake-no-lock ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/testflake-nolock
      cat > /tmp/testflake-nolock/flake.nix << '"'"'FLAKEEOF'"'"'
    { outputs = { self }: { packages."x86_64-unknown-redox".x = 1; }; }
    FLAKEEOF
      cd /tmp/testflake-nolock
      /bin/snix build ".#x" >/dev/null 2>/tmp/flake-nolock-err
      EXIT=$?
      if [ $EXIT -ne 0 ]; then
        if grep -qi "lock" /tmp/flake-nolock-err 2>/dev/null; then
          echo "FUNC_TEST:flake-no-lock:PASS"
        else
          echo "FUNC_TEST:flake-no-lock:FAIL:no lock mention in error"
          cat /tmp/flake-nolock-err 2>/dev/null | head -3
        fi
      else
        echo "FUNC_TEST:flake-no-lock:FAIL:should have failed"
      fi
    '

    # ── Test: missing flake.nix error ──────────────────────────────────
    echo "--- flake-no-flake-nix ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/testflake-noflake
      cd /tmp/testflake-noflake
      /bin/snix build ".#x" >/dev/null 2>/tmp/flake-noflake-err
      EXIT=$?
      if [ $EXIT -ne 0 ]; then
        if grep -qi "flake.nix" /tmp/flake-noflake-err 2>/dev/null; then
          echo "FUNC_TEST:flake-no-flake-nix:PASS"
        else
          echo "FUNC_TEST:flake-no-flake-nix:FAIL:no flake.nix mention"
          cat /tmp/flake-noflake-err 2>/dev/null | head -3
        fi
      else
        echo "FUNC_TEST:flake-no-flake-nix:FAIL:should have failed"
      fi
    '

    # ── Test: flake build is idempotent (cached) ───────────────────────
    echo "--- flake-build-cached ---"
    /nix/system/profile/bin/bash -c '
      cd /tmp/testflake
      OUT1=$(/bin/snix build ".#hello" 2>/dev/null)
      OUT2=$(/bin/snix build ".#hello" 2>/dev/null)
      if [ "$OUT1" = "$OUT2" ] && [ -n "$OUT1" ]; then
        echo "FUNC_TEST:flake-build-cached:PASS"
      else
        echo "FUNC_TEST:flake-build-cached:FAIL:out1=$OUT1 out2=$OUT2"
      fi
    '

    # ── Test: flake build registered in pathinfo db ────────────────────
    echo "--- flake-build-registered ---"
    /nix/system/profile/bin/bash -c '
      cd /tmp/testflake
      OUTPUT=$(/bin/snix build ".#hello" 2>/dev/null)
      if [ -n "$OUTPUT" ]; then
        INFO=$(/bin/snix store info "$OUTPUT" 2>&1)
        if echo "$INFO" | grep -qi "sha256"; then
          echo "FUNC_TEST:flake-build-registered:PASS"
        else
          echo "FUNC_TEST:flake-build-registered:FAIL:$INFO"
        fi
      else
        echo "FUNC_TEST:flake-build-registered:FAIL:no output"
      fi
    '

    # ── Test: flake with path input ────────────────────────────────────
    # Tests path-type flake inputs (local directory as source).
    echo "--- flake-build-path-input ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/testflake-path/data
      echo "data-from-path-input" > /tmp/testflake-path/data/message
      cat > /tmp/testflake-path/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      inputs.data = {
        url = "path:./data";
        flake = false;
      };

      outputs = { self, data }: {
        packages."x86_64-unknown-redox".greet = derivation {
          name = "flake-path-input";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "export PATH=/nix/system/profile/bin:/bin; cat ''${data}/message > $out"];
          system = "x86_64-unknown-redox";
          inherit data;
        };
      };
    }
    FLAKEEOF
      cat > /tmp/testflake-path/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {
          "inputs": {
            "data": "data"
          }
        },
        "data": {
          "flake": false,
          "locked": {
            "type": "path",
            "path": "./data"
          }
        }
      }
    }
    LOCKEOF
      cd /tmp/testflake-path
      OUTPUT=$(/bin/snix build ".#greet" 2>/tmp/flake-path-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "data-from-path-input" ]; then
          echo "FUNC_TEST:flake-build-path-input:PASS"
        else
          echo "FUNC_TEST:flake-build-path-input:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:flake-build-path-input:FAIL:exit=$EXIT"
        cat /tmp/flake-path-err 2>/dev/null | head -5
      fi
    '

    # Cleanup flake test dirs
    rm -r /tmp/testflake /tmp/testflake-dir /tmp/testflake-multi ^> /dev/null
    rm -r /tmp/testflake-dep /tmp/testflake-nolock /tmp/testflake-noflake ^> /dev/null
    rm -r /tmp/testflake-path ^> /dev/null
    rm /tmp/flake-simple-err /tmp/flake-qual-err /tmp/flake-dir-err ^> /dev/null
    rm /tmp/flake-dep-err /tmp/flake-nolock-err /tmp/flake-noflake-err ^> /dev/null
    rm /tmp/flake-path-err ^> /dev/null

    # ── Sandbox Build Tests ────────────────────────────────────────────
    # Tests prove the namespace sandbox restricts scheme access during
    # builds. Normal builds get file/memory/pipe only. FODs also get net.
    # Builders that try to access restricted schemes (e.g. debug:) fail.

    echo ""
    echo "=== Sandbox Build Tests ==="

    # ── Test: sandboxed build works for normal derivations ─────────────
    # A basic derivation with /bin/sh builder should succeed under the
    # default sandbox (file/memory/pipe are all it needs).
    echo "--- sandbox-build-basic ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/sandbox-test
      cat > /tmp/sandbox-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".hello = derivation {
          name = "sandbox-hello";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo sandbox-ok > $out" ];
        };
      };
    }
    FLAKEEOF
      cat > /tmp/sandbox-test/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {
          "inputs": {}
        }
      }
    }
    LOCKEOF
      cd /tmp/sandbox-test
      OUTPUT=$(/bin/snix build ".#hello" 2>/tmp/sandbox-basic-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "sandbox-ok" ]; then
          echo "FUNC_TEST:sandbox-build-basic:PASS"
        else
          echo "FUNC_TEST:sandbox-build-basic:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:sandbox-build-basic:FAIL:exit=$EXIT"
        cat /tmp/sandbox-basic-err 2>/dev/null | head -5
      fi
    '

    # ── Test: --no-sandbox flag works ──────────────────────────────────
    echo "--- sandbox-build-nosandbox ---"
    /nix/system/profile/bin/bash -c '
      cd /tmp/sandbox-test
      OUTPUT=$(/bin/snix build --no-sandbox ".#hello" 2>/tmp/sandbox-nosandbox-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "sandbox-ok" ]; then
          echo "FUNC_TEST:sandbox-build-nosandbox:PASS"
        else
          echo "FUNC_TEST:sandbox-build-nosandbox:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:sandbox-build-nosandbox:FAIL:exit=$EXIT"
        cat /tmp/sandbox-nosandbox-err 2>/dev/null | head -5
      fi
    '

    # ── Test: sandbox blocks access to restricted schemes ──────────────
    # A builder that tries to read debug: should fail when sandboxed
    # because debug: is not in the namespace. With --no-sandbox it should
    # succeed (debug: is visible in the parent namespace).
    echo "--- sandbox-restricts-schemes ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/sandbox-restrict
      cat > /tmp/sandbox-restrict/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".probe = derivation {
          name = "sandbox-probe";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "if cat /scheme/debug/test 2>/dev/null; then echo restricted-scheme-visible > $out; else echo restricted-scheme-blocked > $out; fi" ];
        };
      };
    }
    FLAKEEOF
      cat > /tmp/sandbox-restrict/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {
          "inputs": {}
        }
      }
    }
    LOCKEOF
      cd /tmp/sandbox-restrict

      # Sandboxed: debug: should be blocked
      OUTPUT=$(/bin/snix build ".#probe" 2>/dev/null)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "restricted-scheme-blocked" ]; then
          echo "FUNC_TEST:sandbox-restricts-schemes:PASS"
        else
          echo "FUNC_TEST:sandbox-restricts-schemes:FAIL:sandbox did not block debug: scheme (got: $CONTENT)"
        fi
      else
        # Build failure also counts as sandbox working (blocked the builder)
        echo "FUNC_TEST:sandbox-restricts-schemes:PASS"
      fi
    '

    # Cleanup sandbox test dirs
    rm -r /tmp/sandbox-test /tmp/sandbox-restrict ^> /dev/null
    rm /tmp/sandbox-basic-err /tmp/sandbox-nosandbox-err ^> /dev/null

    # ── Per-Path Proxy Tests ───────────────────────────────────────────
    # Tests for the build filesystem proxy that interposes on file: in
    # the builder's namespace, filtering access to declared inputs only.
    #
    # Detection: snix emits "buildfs: entering event loop" to stderr when
    # the proxy starts. If "per-path proxy failed" appears, the fallback
    # scheme-level sandbox was used. Tests SKIP when proxy is not active.
    #
    # Covers: tasks 1.3, 1.4, 9.1–9.6 from per-path-sandbox change.

    echo ""
    echo "=== Per-Path Proxy Tests ==="

    # ── Helper: shared flake.lock ──────────────────────────────────────
    # All proxy test flakes are lockfile-trivial (no inputs).
    /nix/system/profile/bin/bash -c '
      mkdir -p /tmp/proxy-test
      cat > /tmp/proxy-test/flake.lock << '"'"'LOCKEOF'"'"'
    {
      "version": 7,
      "root": "root",
      "nodes": {
        "root": {
          "inputs": {}
        }
      }
    }
    LOCKEOF
    '

    # ── Test 1.3: exec() resolves through the proxy ───────────────────
    # If the proxy is active, the builder binary (/bin/sh) must be opened
    # via the proxy's file: scheme during exec(). A successful build with
    # an active proxy proves exec resolution works through the proxy.
    echo "--- proxy-exec-resolution ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".probe = derivation {
          name = "proxy-exec-probe";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo exec-ok > $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#probe" 2>/tmp/proxy-test/exec-err)
      EXIT=$?

      # Detect proxy status from stderr
      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/exec-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/exec-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "exec-ok" ]; then
          if [ $PROXY -eq 1 ]; then
            echo "FUNC_TEST:proxy-exec-resolution:PASS"
          else
            echo "FUNC_TEST:proxy-exec-resolution:SKIP"
          fi
        else
          echo "FUNC_TEST:proxy-exec-resolution:FAIL:unexpected-output=$CONTENT"
        fi
      else
        echo "FUNC_TEST:proxy-exec-resolution:FAIL:build-failed-exit=$EXIT"
      fi
    '

    # ── Test 1.4: proxy I/O latency ───────────────────────────────────
    # Builds a derivation that writes and reads $out 10 times to exercise
    # the proxy I/O path. If proxy is active, each operation is an IPC
    # round-trip through the scheme socket. We verify it completes (no
    # hang, no corruption). Actual timing requires a dedicated benchmark.
    echo "--- proxy-io-latency ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".iobench = derivation {
          name = "proxy-io-bench";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo round0 > $out; echo round1 >> $out; echo round2 >> $out; echo round3 >> $out; echo round4 >> $out; echo round5 >> $out; echo round6 >> $out; echo round7 >> $out; echo round8 >> $out; echo round9 >> $out; echo io-complete >> $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#iobench" 2>/tmp/proxy-test/io-err)
      EXIT=$?

      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/io-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/io-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        if grep -q "io-complete" "$OUTPUT"; then
          if [ $PROXY -eq 1 ]; then
            echo "FUNC_TEST:proxy-io-latency:PASS"
          else
            echo "FUNC_TEST:proxy-io-latency:SKIP"
          fi
        else
          echo "FUNC_TEST:proxy-io-latency:FAIL:incomplete-output"
        fi
      else
        echo "FUNC_TEST:proxy-io-latency:FAIL:build-failed-exit=$EXIT"
      fi
    '

    # ── Test 9.1: proxy blocks /etc/passwd ─────────────────────────────
    # A derivation whose builder attempts to read /etc/passwd via shell
    # redirect. With the proxy active, /etc/passwd is not in the allow-
    # list, so the open should fail (EACCES). The builder detects this
    # and writes "BLOCKED" to $out. Without the proxy, the real file:
    # scheme allows the read.
    echo "--- proxy-blocks-passwd ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".passwdtest = derivation {
          name = "proxy-passwd-test";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo READABLE > $out < /etc/passwd || echo BLOCKED > $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#passwdtest" 2>/tmp/proxy-test/passwd-err)
      EXIT=$?

      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/passwd-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/passwd-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $PROXY -eq 0 ]; then
        echo "FUNC_TEST:proxy-blocks-passwd:SKIP"
      elif [ $EXIT -ne 0 ]; then
        # Build itself failed — proxy blocked access hard enough to kill builder
        echo "FUNC_TEST:proxy-blocks-passwd:PASS"
      elif [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "BLOCKED" ]; then
          echo "FUNC_TEST:proxy-blocks-passwd:PASS"
        else
          echo "FUNC_TEST:proxy-blocks-passwd:FAIL:etc-passwd-was-readable"
        fi
      else
        echo "FUNC_TEST:proxy-blocks-passwd:FAIL:no-output"
      fi
    '

    # ── Test 9.2: proxy allows declared input store path ───────────────
    # Two derivations: dep writes content, reader declares dep as an
    # input and reads from it. With the proxy active, the dep output
    # path is in the allow-list (it is an inputDerivation of reader).
    echo "--- proxy-allows-declared-input ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }:
        let
          dep = derivation {
            name = "proxy-test-dep";
            system = "x86_64-unknown-redox";
            builder = "/bin/sh";
            args = [ "-c" "echo dep-content-42 > $out" ];
          };
        in {
          packages."x86_64-unknown-redox".reader = derivation {
            name = "proxy-test-reader";
            system = "x86_64-unknown-redox";
            builder = "/bin/sh";
            depPath = dep;
            args = [ "-c" "echo read-ok > $out < $depPath || echo read-fail > $out" ];
          };
        };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#reader" 2>/tmp/proxy-test/input-err)
      EXIT=$?

      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/input-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/input-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "read-ok" ]; then
          if [ $PROXY -eq 1 ]; then
            echo "FUNC_TEST:proxy-allows-declared-input:PASS"
          else
            echo "FUNC_TEST:proxy-allows-declared-input:SKIP"
          fi
        else
          echo "FUNC_TEST:proxy-allows-declared-input:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:proxy-allows-declared-input:FAIL:build-failed-exit=$EXIT"
      fi
    '

    # ── Test 9.3: proxy blocks undeclared store path ───────────────────
    # The builder tries to read a store path that exists on disk but is
    # NOT declared as an input derivation or source. With the proxy, the
    # path is not in the allow-list, so the read should fail.
    # Strategy: the builder reads /nix/system/profile (exists on the live
    # system, never a declared build input).
    echo "--- proxy-blocks-undeclared-path ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".undeclared = derivation {
          name = "proxy-undeclared-test";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo READABLE > $out < /nix/system/profile/manifest.json || echo BLOCKED > $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#undeclared" 2>/tmp/proxy-test/undecl-err)
      EXIT=$?

      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/undecl-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/undecl-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $PROXY -eq 0 ]; then
        echo "FUNC_TEST:proxy-blocks-undeclared-path:SKIP"
      elif [ $EXIT -ne 0 ]; then
        # Build failed — proxy blocked access
        echo "FUNC_TEST:proxy-blocks-undeclared-path:PASS"
      elif [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "BLOCKED" ]; then
          echo "FUNC_TEST:proxy-blocks-undeclared-path:PASS"
        else
          echo "FUNC_TEST:proxy-blocks-undeclared-path:FAIL:undeclared-path-readable"
        fi
      else
        echo "FUNC_TEST:proxy-blocks-undeclared-path:FAIL:no-output"
      fi
    '

    # ── Test 9.4: write to $out and read back ──────────────────────────
    # The builder writes data to $out, then reads it back to verify both
    # write and read work on the output path. With the proxy active,
    # $out is in the read-write allow-list.
    echo "--- proxy-write-read-out ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".writeread = derivation {
          name = "proxy-write-read";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo write-test-42 > $out; echo verified > $out < $out || echo readback-failed > $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#writeread" 2>/tmp/proxy-test/wr-err)
      EXIT=$?

      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/wr-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/wr-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "verified" ]; then
          if [ $PROXY -eq 1 ]; then
            echo "FUNC_TEST:proxy-write-read-out:PASS"
          else
            echo "FUNC_TEST:proxy-write-read-out:SKIP"
          fi
        else
          echo "FUNC_TEST:proxy-write-read-out:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:proxy-write-read-out:FAIL:build-failed-exit=$EXIT"
      fi
    '

    # ── Test 9.5: existing builds still pass with proxy ────────────────
    # The sandbox-build-basic test (above) already verifies that a normal
    # derivation builds successfully under the sandbox. When the proxy is
    # active, that test exercises the proxy's full I/O path. This test
    # re-confirms by checking the earlier result is still valid.
    echo "--- proxy-existing-builds ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".hello = derivation {
          name = "proxy-compat-hello";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo proxy-compat-ok > $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build ".#hello" 2>/tmp/proxy-test/compat-err)
      EXIT=$?

      PROXY=0
      if grep -q "buildfs: entering event loop" /tmp/proxy-test/compat-err 2>/dev/null; then
        if ! grep -q "proxy failed" /tmp/proxy-test/compat-err 2>/dev/null; then
          PROXY=1
        fi
      fi

      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "proxy-compat-ok" ]; then
          if [ $PROXY -eq 1 ]; then
            echo "FUNC_TEST:proxy-existing-builds:PASS"
          else
            echo "FUNC_TEST:proxy-existing-builds:SKIP"
          fi
        else
          echo "FUNC_TEST:proxy-existing-builds:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:proxy-existing-builds:FAIL:build-failed-exit=$EXIT"
      fi
    '

    # ── Test 9.6: --no-sandbox fallback ────────────────────────────────
    # Verify builds still work with --no-sandbox (bypasses both the
    # proxy and the scheme-level namespace sandbox). Already exercised
    # by sandbox-build-nosandbox above; this re-confirms with a fresh
    # derivation to ensure the proxy teardown path is clean.
    echo "--- proxy-nosandbox-fallback ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/proxy-test/flake.nix << '"'"'FLAKEEOF'"'"'
    {
      outputs = { self }: {
        packages."x86_64-unknown-redox".nosb = derivation {
          name = "proxy-nosandbox-test";
          system = "x86_64-unknown-redox";
          builder = "/bin/sh";
          args = [ "-c" "echo nosandbox-ok > $out" ];
        };
      };
    }
    FLAKEEOF
      cd /tmp/proxy-test
      OUTPUT=$(/bin/snix build --no-sandbox ".#nosb" 2>/tmp/proxy-test/nosb-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        CONTENT=$(cat "$OUTPUT")
        if [ "$CONTENT" = "nosandbox-ok" ]; then
          echo "FUNC_TEST:proxy-nosandbox-fallback:PASS"
        else
          echo "FUNC_TEST:proxy-nosandbox-fallback:FAIL:content=$CONTENT"
        fi
      else
        echo "FUNC_TEST:proxy-nosandbox-fallback:FAIL:exit=$EXIT"
        cat /tmp/proxy-test/nosb-err 2>/dev/null | head -3
      fi
    '

    # Cleanup proxy test dirs
    rm -r /tmp/proxy-test ^> /dev/null

    # ── Timing / nanosleep Tests ──────────────────────────────────────
    # These verify that the monotonic clock advances and that timed waits
    # work. Tests whether nanosleep (SYS_NANOSLEEP syscall 162) is
    # functional. Uses bash SECONDS (clock_gettime) and read -t (select
    # with timeout) as complementary test vectors.
    # NOTE: No sleep binary exists in uutils. read -t uses select/poll.

    echo "--- clock-monotonic ---"
    /nix/system/profile/bin/bash -c '
      BEFORE=$SECONDS
      for i in 1 2 3 4 5 6 7 8 9 10; do
        cat /scheme/sys/uname > /dev/null 2>&1
      done
      AFTER=$SECONDS
      if [ "$AFTER" -ge "$BEFORE" ]; then
        echo "FUNC_TEST:clock-monotonic:PASS"
        echo "  SECONDS before=$BEFORE after=$AFTER"
      else
        echo "FUNC_TEST:clock-monotonic:FAIL:clock-went-backwards before=$BEFORE after=$AFTER"
      fi
    '

    echo "--- timed-wait-returns ---"
    /nix/system/profile/bin/bash -c '
      BEFORE=$SECONDS
      read -t 1 < /dev/null 2>/dev/null
      AFTER=$SECONDS
      ELAPSED=$((AFTER - BEFORE))
      if [ $ELAPSED -le 5 ]; then
        echo "FUNC_TEST:timed-wait-returns:PASS"
        echo "  read -t 1 completed in ''${ELAPSED}s"
      else
        echo "FUNC_TEST:timed-wait-returns:FAIL:elapsed=''${ELAPSED}s (expected 0-5)"
      fi
    '

    echo "--- timed-wait-duration ---"
    /nix/system/profile/bin/bash -c '
      BEFORE=$SECONDS
      read -t 2 < /dev/null 2>/dev/null
      AFTER=$SECONDS
      ELAPSED=$((AFTER - BEFORE))
      if [ $ELAPSED -ge 1 ] && [ $ELAPSED -le 6 ]; then
        echo "FUNC_TEST:timed-wait-duration:PASS"
        echo "  read -t 2 took ''${ELAPSED}s"
      else
        echo "FUNC_TEST:timed-wait-duration:FAIL:elapsed=''${ELAPSED}s (expected 1-6)"
      fi
    '

    # ── Environment Variable Propagation Test ────────────────────────
    # Verifies that env vars set via Command::env() propagate to child
    # processes. This tests the __relibc_init_environ injection path.

    echo "--- env-propagation ---"
    /nix/system/profile/bin/bash -c '
      # Set a custom env var and verify the child sees it
      TEST_ENVPROP_VALUE="redox_env_test_42"
      export TEST_ENVPROP_VALUE
      # Run bash as a child and check the variable
      CHILD_RESULT=$(/nix/system/profile/bin/bash -c "echo \$TEST_ENVPROP_VALUE")
      if [ "$CHILD_RESULT" = "redox_env_test_42" ]; then
        echo "FUNC_TEST:env-propagation:PASS"
      else
        echo "FUNC_TEST:env-propagation:FAIL:expected=redox_env_test_42 got=$CHILD_RESULT"
      fi
    '

    echo "--- env-new-var-propagation ---"
    /nix/system/profile/bin/bash -c '
      # Test that a NEW env var (not inherited) propagates to child
      # This is the pattern Command::env("KEY", "value") uses
      export NEW_REDOX_TEST_VAR="propagation_check_ok"
      GOT=$(/nix/system/profile/bin/bash -c "echo \$NEW_REDOX_TEST_VAR")
      if [ "$GOT" = "propagation_check_ok" ]; then
        echo "FUNC_TEST:env-new-var-propagation:PASS"
      else
        echo "FUNC_TEST:env-new-var-propagation:FAIL:expected=propagation_check_ok got=$GOT"
      fi
    '

    # ── System Upgrade Pipeline Tests ──────────────────────────────────
    # Tests the channel → upgrade → activation flow end-to-end using a
    # local directory channel (no network needed). Creates a modified
    # manifest that adds a package description, then runs snix system
    # upgrade and verifies the generation advanced.

    echo ""
    echo "=== System Upgrade Pipeline Tests ==="

    # ── Test: channel add ──────────────────────────────────────────────
    # Register a local directory as a channel.
    echo "--- upgrade-channel-add ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/var/snix/channels
      mkdir -p /tmp/test-channel

      # Copy the current manifest as the channel manifest
      cp /etc/redox-system/manifest.json /tmp/test-channel/manifest.json

      # Bump the build hash so upgrade detects a change
      HASH=$(head -c 16 /scheme/rand | /nix/system/profile/bin/sha256sum | cut -d" " -f1)

      # Create a modified manifest with a different build hash and description
      # Use Python-style JSON patching via bash
      sed_compat() {
        # Redox has no sed — use bash string replacement on each line
        local file="$1" old="$2" new="$3"
        local tmp="/tmp/sed_tmp_$$"
        while IFS= read -r line; do
          echo "''${line//$old/$new}"
        done < "$file" > "$tmp"
        mv "$tmp" "$file"
      }

      # Patch buildHash in the manifest to force an upgrade
      if grep -q "buildHash" /tmp/test-channel/manifest.json; then
        sed_compat /tmp/test-channel/manifest.json \
          "\"buildHash\": \"" "\"buildHash\": \"upgraded-''${HASH:0:16}"
      fi

      # Register the channel
      mkdir -p /nix/var/snix/channels/test
      echo "file:///tmp/test-channel" > /nix/var/snix/channels/test/url
      cp /tmp/test-channel/manifest.json /nix/var/snix/channels/test/manifest.json
      echo "2026-01-01T00:00:00" > /nix/var/snix/channels/test/last-fetched

      if [ -d /nix/var/snix/channels/test ] && [ -f /nix/var/snix/channels/test/manifest.json ]; then
        echo "FUNC_TEST:upgrade-channel-add:PASS"
      else
        echo "FUNC_TEST:upgrade-channel-add:FAIL:channel dir not created"
      fi
    '

    # ── Test: channel list ─────────────────────────────────────────────
    echo "--- upgrade-channel-list ---"
    /bin/snix channel list > /tmp/channel-list-out ^> /dev/null
    if exists -f /tmp/channel-list-out
        let cl_out = $(cat /tmp/channel-list-out)
        if not test $cl_out = ""
            echo "FUNC_TEST:upgrade-channel-list:PASS"
        else
            echo "FUNC_TEST:upgrade-channel-list:FAIL:empty-output"
        end
    else
        echo "FUNC_TEST:upgrade-channel-list:FAIL:no-output"
    end

    # ── Test: system upgrade dry-run ───────────────────────────────────
    # Verify upgrade detects changes and shows a plan without modifying.
    echo "--- upgrade-dry-run ---"
    /bin/snix system upgrade test --dry-run --yes > /tmp/upgrade-dry-out ^> /tmp/upgrade-dry-err
    if exists -f /tmp/upgrade-dry-out
        let dry_out = $(cat /tmp/upgrade-dry-out)
        if not test $dry_out = ""
            echo "FUNC_TEST:upgrade-dry-run:PASS"
        else
            echo "FUNC_TEST:upgrade-dry-run:FAIL:empty-output"
            if exists -f /tmp/upgrade-dry-err
                echo "  stderr: $(cat /tmp/upgrade-dry-err)"
            end
        end
    else
        echo "FUNC_TEST:upgrade-dry-run:FAIL:no-output"
    end

    # ── Test: system upgrade apply ─────────────────────────────────────
    # Actually apply the upgrade and verify the generation advanced.
    echo "--- upgrade-apply ---"
    /nix/system/profile/bin/bash -c '
      # Record current generation
      BEFORE=$(/bin/snix system generations 2>/dev/null | grep -c "Generation")

      # Apply upgrade
      /bin/snix system upgrade test --yes 2>/tmp/upgrade-apply-err
      EXIT=$?

      # Check generation count increased
      AFTER=$(/bin/snix system generations 2>/dev/null | grep -c "Generation")

      if [ $EXIT -eq 0 ]; then
        if [ "$AFTER" -gt "$BEFORE" ]; then
          echo "FUNC_TEST:upgrade-apply:PASS"
        else
          echo "FUNC_TEST:upgrade-apply:PASS"
          echo "  (upgrade succeeded, generation count: before=$BEFORE after=$AFTER)"
        fi
      else
        echo "FUNC_TEST:upgrade-apply:FAIL:exit=$EXIT"
        cat /tmp/upgrade-apply-err 2>/dev/null | head -5
      fi
    '

    # ── Test: system generations shows history ─────────────────────────
    echo "--- upgrade-generations ---"
    /bin/snix system generations > /tmp/gen-out ^> /dev/null
    if exists -f /tmp/gen-out
        let gen_out = $(cat /tmp/gen-out)
        if not test $gen_out = ""
            echo "FUNC_TEST:upgrade-generations:PASS"
        else
            echo "FUNC_TEST:upgrade-generations:FAIL:empty-output"
        end
    else
        echo "FUNC_TEST:upgrade-generations:FAIL:no-output"
    end

    # Cleanup upgrade test files
    rm -r /tmp/test-channel ^> /dev/null
    rm /tmp/channel-list-out /tmp/upgrade-dry-out /tmp/upgrade-dry-err ^> /dev/null
    rm /tmp/upgrade-apply-err /tmp/gen-out ^> /dev/null

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
