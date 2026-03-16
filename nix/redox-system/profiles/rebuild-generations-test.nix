# Rebuild & Generations Test Profile for RedoxOS
#
# Tests the full declarative rebuild lifecycle:
#   1. Pre-flight: configuration.nix + manifest.json + snix exist
#   2. show-config: parse and display the current config
#   3. dry-run rebuild: preview changes without applying
#   4. Rebuild with hostname change: verify activation + generation created
#   5. List generations: verify at least 2 exist
#   6. Rollback: revert to original hostname, verify state
#   7. Rollback generation: verify generation 3 exists with correct manifest
#   8. Package addition: add package to config, rebuild, verify in manifest
#
# Test protocol (same as functional-test):
#   FUNC_TESTS_START              -> suite starting
#   FUNC_TEST:<name>:PASS         -> test passed
#   FUNC_TEST:<name>:FAIL:<reason>-> test failed
#   FUNC_TESTS_COMPLETE           -> suite finished
#
# Does NOT test the bridge rebuild path (covered by bridge-rebuild-test).
# Does NOT test network-based upgrade/channels (covered by network tests).
#
# Usage: redoxSystem { modules = [ ./profiles/rebuild-generations-test.nix ]; ... }

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Rebuild & Generations Test"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Phase 1: Pre-flight checks ─────────────────────────────
    echo "--- Phase 1: Pre-flight checks ---"

    if exists -f /bin/snix
        echo "FUNC_TEST:snix-exists:PASS"
    else
        echo "FUNC_TEST:snix-exists:FAIL:snix not in /bin"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    if exists -f /etc/redox-system/configuration.nix
        echo "FUNC_TEST:config-nix-exists:PASS"
    else
        echo "FUNC_TEST:config-nix-exists:FAIL:no configuration.nix"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    if exists -f /etc/redox-system/manifest.json
        echo "FUNC_TEST:manifest-exists:PASS"
    else
        echo "FUNC_TEST:manifest-exists:FAIL:no manifest.json"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    if exists -f /nix/cache/packages.json
        echo "FUNC_TEST:cache-index-exists:PASS"
    else
        echo "FUNC_TEST:cache-index-exists:FAIL:no packages.json in cache"
    end

    # Save original hostname to file for rollback verification
    # (Avoids Ion quoting issues when passing to bash -c blocks)
    if exists -f /etc/hostname
        cat /etc/hostname > /tmp/original_hostname
        echo "DEBUG: original hostname: $(cat /tmp/original_hostname)"
        echo "FUNC_TEST:original-hostname-read:PASS"
    else
        echo "FUNC_TEST:original-hostname-read:FAIL:no /etc/hostname"
    end

    # ── Phase 2: show-config ───────────────────────────────────
    echo ""
    echo "--- Phase 2: show-config ---"

    /bin/snix system show-config > /tmp/showconfig_out ^> /tmp/showconfig_err
    if exists -f /tmp/showconfig_out
        let sc_size = $(wc -c < /tmp/showconfig_out)
        if test $sc_size -gt 10
            echo "FUNC_TEST:show-config-runs:PASS"
        else
            echo "FUNC_TEST:show-config-runs:FAIL:output too small ($sc_size bytes)"
        end
    else
        echo "FUNC_TEST:show-config-runs:FAIL:no output file"
    end

    # Verify show-config mentions hostname
    grep hostname /tmp/showconfig_out > /dev/null ^> /dev/null
    if test $? -eq 0
        echo "FUNC_TEST:show-config-has-hostname:PASS"
    else
        echo "FUNC_TEST:show-config-has-hostname:FAIL:no hostname in output"
    end

    # ── Phase 3: dry-run rebuild ───────────────────────────────
    echo ""
    echo "--- Phase 3: dry-run rebuild ---"

    # Save manifest hash before dry-run
    /nix/system/profile/bin/bash -c 'wc -c < /etc/redox-system/manifest.json' > /tmp/manifest_size_before

    /bin/snix system rebuild --dry-run > /tmp/dryrun_out ^> /tmp/dryrun_err
    if test $? -eq 0
        echo "FUNC_TEST:rebuild-dryrun-succeeds:PASS"
    else
        echo "FUNC_TEST:rebuild-dryrun-succeeds:FAIL:exit code nonzero"
        echo "DEBUG: dry-run stderr:"
        cat /tmp/dryrun_err
    end

    # Verify manifest unchanged after dry-run
    /nix/system/profile/bin/bash -c 'wc -c < /etc/redox-system/manifest.json' > /tmp/manifest_size_after
    /nix/system/profile/bin/bash -c '
        before=$(cat /tmp/manifest_size_before)
        after=$(cat /tmp/manifest_size_after)
        if [ "$before" = "$after" ]; then
            echo FUNC_TEST:dryrun-no-change:PASS
        else
            echo "FUNC_TEST:dryrun-no-change:FAIL:manifest size changed ($before -> $after)"
        fi
    '

    # ── Phase 3b: auto-routing with no changes, no bridge ──────
    echo ""
    echo "--- Phase 3b: auto-routing unchanged config ---"

    # snix system rebuild (no flags) with unchanged config should auto-route
    # to local path and succeed, even without bridge available
    /bin/snix system rebuild > /tmp/auto_out ^> /tmp/auto_err
    if test $? -eq 0
        echo "FUNC_TEST:auto-route-config-only:PASS"
    else
        echo "FUNC_TEST:auto-route-config-only:FAIL:auto-rebuild failed without bridge"
        echo "DEBUG auto stderr:"
        cat /tmp/auto_err
    end

    # ── Phase 4: rebuild with hostname change ──────────────────
    echo ""
    echo "--- Phase 4: rebuild with hostname change ---"

    # Modify configuration.nix to change hostname
    /nix/system/profile/bin/bash -c '
        cfg="/etc/redox-system/configuration.nix"
        if grep -q "hostname" "$cfg"; then
            # Replace the hostname line
            sed -i "s/hostname = \"[^\"]*\"/hostname = \"test-rebuild-host\"/" "$cfg"
            if grep -q "test-rebuild-host" "$cfg"; then
                echo FUNC_TEST:config-modified:PASS
            else
                echo "FUNC_TEST:config-modified:FAIL:sed did not change hostname"
            fi
        else
            echo "FUNC_TEST:config-modified:FAIL:no hostname in config"
        fi
    '

    # Run the actual rebuild
    echo "DEBUG: starting snix system rebuild"
    /bin/snix system rebuild > /tmp/rebuild_out ^> /tmp/rebuild_err

    # Check rebuild exit (use bash to get reliable $?)
    /nix/system/profile/bin/bash -c '
        if [ -f /tmp/rebuild_out ]; then
            if grep -q "rebuilt from" /tmp/rebuild_out 2>/dev/null || grep -q "Switched to generation" /tmp/rebuild_out 2>/dev/null; then
                echo FUNC_TEST:rebuild-succeeds:PASS
            else
                echo "FUNC_TEST:rebuild-succeeds:FAIL:no success message in output"
                echo "DEBUG rebuild stdout:"
                cat /tmp/rebuild_out
                echo "DEBUG rebuild stderr:"
                cat /tmp/rebuild_err 2>/dev/null || true
            fi
        else
            echo "FUNC_TEST:rebuild-succeeds:FAIL:no output file"
        fi
    '

    # Verify hostname was updated
    /nix/system/profile/bin/bash -c '
        if [ -f /etc/hostname ]; then
            actual=$(cat /etc/hostname)
            if [ "$actual" = "test-rebuild-host" ]; then
                echo FUNC_TEST:hostname-updated:PASS
            else
                echo "FUNC_TEST:hostname-updated:FAIL:expected test-rebuild-host got $actual"
            fi
        else
            echo "FUNC_TEST:hostname-updated:FAIL:no /etc/hostname"
        fi
    '

    # Verify manifest updated
    /nix/system/profile/bin/bash -c '
        if grep -q "test-rebuild-host" /etc/redox-system/manifest.json; then
            echo FUNC_TEST:manifest-hostname-updated:PASS
        else
            echo "FUNC_TEST:manifest-hostname-updated:FAIL:manifest does not contain new hostname"
        fi
    '

    # Verify generation directory created
    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        if [ -d "$gen_dir" ]; then
            count=$(ls "$gen_dir" | wc -l)
            if [ "$count" -ge 2 ]; then
                echo "FUNC_TEST:generations-created:PASS"
            else
                echo "FUNC_TEST:generations-created:FAIL:expected >=2 generations, found $count"
                ls -la "$gen_dir" 2>/dev/null || true
            fi
        else
            echo "FUNC_TEST:generations-created:FAIL:no generations directory"
        fi
    '

    # ── Phase 5: list generations ──────────────────────────────
    echo ""
    echo "--- Phase 5: list generations ---"

    /bin/snix system generations > /tmp/gens_out ^> /tmp/gens_err

    /nix/system/profile/bin/bash -c '
        if [ -f /tmp/gens_out ]; then
            line_count=$(wc -l < /tmp/gens_out)
            if [ "$line_count" -ge 2 ]; then
                echo FUNC_TEST:generations-list-output:PASS
            else
                echo "FUNC_TEST:generations-list-output:FAIL:only $line_count lines"
                cat /tmp/gens_out
            fi
        else
            echo "FUNC_TEST:generations-list-output:FAIL:no output"
        fi
    '

    # Verify generation 2 exists in listing
    /nix/system/profile/bin/bash -c '
        if grep -q "2" /tmp/gens_out 2>/dev/null; then
            echo FUNC_TEST:generations-has-gen2:PASS
        else
            echo "FUNC_TEST:generations-has-gen2:FAIL:generation 2 not in output"
        fi
    '

    # ── Phase 6: rollback ──────────────────────────────────────
    echo ""
    echo "--- Phase 6: rollback ---"

    /bin/snix system rollback > /tmp/rollback_out ^> /tmp/rollback_err

    /nix/system/profile/bin/bash -c '
        if [ -f /tmp/rollback_out ]; then
            if grep -q "Rolling back" /tmp/rollback_out 2>/dev/null || grep -q "Switched to generation" /tmp/rollback_out 2>/dev/null || grep -q "rollback" /tmp/rollback_out 2>/dev/null; then
                echo FUNC_TEST:rollback-succeeds:PASS
            else
                echo "FUNC_TEST:rollback-succeeds:FAIL:no rollback message"
                cat /tmp/rollback_out
                cat /tmp/rollback_err 2>/dev/null || true
            fi
        else
            echo "FUNC_TEST:rollback-succeeds:FAIL:no output"
        fi
    '

    # Verify hostname reverted — save original to file to avoid Ion quoting issues
    /nix/system/profile/bin/bash -c '
        if [ -f /etc/hostname ]; then
            actual=$(cat /etc/hostname)
            if [ -f /tmp/original_hostname ]; then
                original=$(cat /tmp/original_hostname)
                if [ "$actual" = "$original" ]; then
                    echo FUNC_TEST:rollback-hostname-reverted:PASS
                else
                    echo "FUNC_TEST:rollback-hostname-reverted:FAIL:expected $original got $actual"
                fi
            else
                echo "FUNC_TEST:rollback-hostname-reverted:FAIL:no saved original hostname"
            fi
        else
            echo "FUNC_TEST:rollback-hostname-reverted:FAIL:no /etc/hostname"
        fi
    '

    # ── Phase 7: verify rollback generation ────────────────────
    echo ""
    echo "--- Phase 7: verify rollback generation ---"

    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        count=$(ls "$gen_dir" 2>/dev/null | wc -l)
        if [ "$count" -ge 3 ]; then
            echo FUNC_TEST:rollback-gen3-exists:PASS
        else
            echo "FUNC_TEST:rollback-gen3-exists:FAIL:expected >=3 generations, found $count"
            ls -la "$gen_dir" 2>/dev/null || true
        fi
    '

    # Verify generation IDs are monotonically increasing
    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        prev=0
        ok=true
        for d in $(ls "$gen_dir" 2>/dev/null | sort -n); do
            if [ "$d" -le "$prev" ]; then
                ok=false
            fi
            prev=$d
        done
        if [ "$ok" = "true" ] && [ "$prev" -gt 0 ]; then
            echo FUNC_TEST:generation-ids-monotonic:PASS
        else
            echo "FUNC_TEST:generation-ids-monotonic:FAIL:non-monotonic ids"
        fi
    '

    # Verify rollback manifest matches original generation
    # Compare hostname in gen1 manifest vs current manifest.
    # Redox grep has no -o flag — use grep to check presence instead.
    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        gen1="$gen_dir/1/manifest.json"
        current="/etc/redox-system/manifest.json"
        if [ -f "$gen1" ] && [ -f "$current" ]; then
            # Read the original hostname from the saved file
            if [ -f /tmp/original_hostname ]; then
                orig=$(cat /tmp/original_hostname)
                if grep -q "$orig" "$current"; then
                    echo FUNC_TEST:rollback-manifest-matches:PASS
                else
                    echo "FUNC_TEST:rollback-manifest-matches:FAIL:current manifest missing original hostname $orig"
                fi
            else
                echo "FUNC_TEST:rollback-manifest-matches:FAIL:no saved original hostname"
            fi
        else
            echo "FUNC_TEST:rollback-manifest-matches:FAIL:missing manifest files"
        fi
    '

    # ── Phase 8: package addition via rebuild ──────────────────
    echo ""
    echo "--- Phase 8: package addition via rebuild ---"

    # Check if ripgrep is in the binary cache (use grep from extrautils)
    if exists -f /nix/cache/packages.json
        grep ripgrep /nix/cache/packages.json > /dev/null ^> /dev/null
        if test $? -eq 0
            echo "FUNC_TEST:ripgrep-in-cache:PASS"
        else
            echo "FUNC_TEST:ripgrep-in-cache:SKIP:ripgrep not in cache"
            echo "FUNC_TEST:pkg-config-modified:SKIP:ripgrep not in cache"
            echo "FUNC_TEST:pkg-rebuild-succeeds:SKIP:ripgrep not in cache"
            echo "FUNC_TEST:pkg-in-manifest:SKIP:ripgrep not in cache"
            echo "FUNC_TESTS_COMPLETE"
            exit
        end
    else
        echo "FUNC_TEST:ripgrep-in-cache:SKIP:no packages.json"
        echo "FUNC_TEST:pkg-config-modified:SKIP:no packages.json"
        echo "FUNC_TEST:pkg-rebuild-succeeds:SKIP:no packages.json"
        echo "FUNC_TEST:pkg-in-manifest:SKIP:no packages.json"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Add ripgrep to packages list in configuration.nix.
    # Replace the commented-out packages block with a clean one-line list.
    # NOTE: After this rebuild the profile will only contain boot-essential
    # packages + ripgrep. bash/sed/grep may vanish from the profile.
    # All post-rebuild assertions use Ion builtins or rg (just installed).
    /nix/system/profile/bin/bash -c '
        cfg="/etc/redox-system/configuration.nix"
        # Remove any existing packages lines (commented or not)
        sed -i "/packages/d" "$cfg"
        # Add a clean packages line before the closing brace
        sed -i "s/^}/  packages = [ \"ripgrep\" ];\n}/" "$cfg"
        if grep -q "ripgrep" "$cfg"; then
            echo FUNC_TEST:pkg-config-modified:PASS
        else
            echo "FUNC_TEST:pkg-config-modified:FAIL:ripgrep not in config after edit"
            cat "$cfg"
        fi
    '

    # Rebuild with package change (--local: no bridge in test VM)
    /bin/snix system rebuild --local > /tmp/pkg_rebuild_out ^> /tmp/pkg_rebuild_err

    # Post-rebuild: bash/grep/sed may be gone from profile (only boot-essential
    # + ripgrep remain). Use rg (ripgrep, just installed) for assertions.
    # rg is now in the profile at /nix/system/profile/bin/rg.
    let pkg_rebuild_ok = "false"
    if exists -f /nix/system/profile/bin/rg
        /nix/system/profile/bin/rg -q "rebuilt from" /tmp/pkg_rebuild_out ^> /dev/null
        if test $? -eq 0
            let pkg_rebuild_ok = "true"
        end
        /nix/system/profile/bin/rg -q "Switched to generation" /tmp/pkg_rebuild_out ^> /dev/null
        if test $? -eq 0
            let pkg_rebuild_ok = "true"
        end
    else
        # rg not in profile means profile rebuild failed
        echo "FUNC_TEST:pkg-rebuild-succeeds:FAIL:rg not in profile after rebuild"
        echo "FUNC_TEST:pkg-in-manifest:FAIL:rg not available"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end
    if test $pkg_rebuild_ok = "true"
        echo "FUNC_TEST:pkg-rebuild-succeeds:PASS"
    else
        echo "FUNC_TEST:pkg-rebuild-succeeds:FAIL:no success message in output"
        echo "DEBUG pkg rebuild stdout:"
        cat /tmp/pkg_rebuild_out
        echo "DEBUG pkg rebuild stderr:"
        cat /tmp/pkg_rebuild_err
    end

    # Verify ripgrep appears in the manifest (use rg itself)
    /nix/system/profile/bin/rg -q ripgrep /etc/redox-system/manifest.json ^> /dev/null
    if test $? -eq 0
        echo "FUNC_TEST:pkg-in-manifest:PASS"
    else
        echo "FUNC_TEST:pkg-in-manifest:FAIL:ripgrep not in manifest"
    end

    # ── Phase 9: switch to specific past generation (gen 3) ────
    #
    # Generation history at this point:
    #   Gen 1: initial build (hostname=redox, all pkgs)
    #   Gen 2: Phase 3b auto-rebuild unchanged config (hostname=redox)
    #   Gen 3: Phase 4 rebuild (hostname=test-rebuild-host, all pkgs)
    #   Gen 4: Phase 6 rollback to gen 2 (hostname=redox)
    #   Gen 5: Phase 8 rebuild (hostname=test-rebuild-host, pkgs=ripgrep)
    #
    # State: Gen 5 active (packages=[ripgrep], hostname=test-rebuild-host)
    # Goal:  Jump to Gen 3 (hostname=test-rebuild-host, ALL original packages)
    #
    # This proves:
    #   - Targeted generation switching works (--generation 3)
    #   - Profile binaries are rebuilt from gen-3's package list
    #     (bash returns to profile — gen 3 had the full package set)
    #   - A new generation (gen 6) is created for the switch
    echo ""
    echo "--- Phase 9: switch to specific generation ---"

    /bin/snix system rollback --generation 3 > /tmp/switch_out ^> /tmp/switch_err
    let switch_rc = $?

    if test $switch_rc -eq 0
        echo "FUNC_TEST:switch-to-gen3-succeeds:PASS"
    else
        echo "FUNC_TEST:switch-to-gen3-succeeds:FAIL:exit=$switch_rc"
        cat /tmp/switch_out
        cat /tmp/switch_err
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Verify hostname is now "test-rebuild-host" (gen 3's value).
    # After switching to gen 3, bash should be back in the profile
    # (gen 3 had the full package set). Use bash for assertions.
    /nix/system/profile/bin/bash -c '
        actual=$(cat /etc/hostname)
        if [ "$actual" = "test-rebuild-host" ]; then
            echo FUNC_TEST:switch-gen3-hostname-live:PASS
        else
            echo "FUNC_TEST:switch-gen3-hostname-live:FAIL:expected test-rebuild-host got $actual"
        fi
    '

    # Verify the manifest agrees
    /nix/system/profile/bin/bash -c '
        if grep -q "test-rebuild-host" /etc/redox-system/manifest.json; then
            echo FUNC_TEST:switch-gen3-hostname-manifest:PASS
        else
            echo "FUNC_TEST:switch-gen3-hostname-manifest:FAIL:manifest missing test-rebuild-host"
        fi
    '

    # Verify profile was rebuilt with gen-3's packages (bash is accessible —
    # gen 3 had the full package set from the original profile)
    if exists -f /nix/system/profile/bin/bash
        echo "FUNC_TEST:switch-gen3-bash-restored:PASS"
    else
        echo "FUNC_TEST:switch-gen3-bash-restored:FAIL:bash not in profile after switch"
    end

    # Verify generation 6 was created (switch creates a new generation)
    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        count=$(ls "$gen_dir" 2>/dev/null | wc -l)
        if [ "$count" -ge 6 ]; then
            echo FUNC_TEST:switch-gen6-created:PASS
        else
            echo "FUNC_TEST:switch-gen6-created:FAIL:expected >=6 generations, found $count"
            ls "$gen_dir" 2>/dev/null
        fi
    '

    # Verify the generation description mentions rollback to gen 3
    /nix/system/profile/bin/bash -c '
        if grep -q "rollback to generation 3" /etc/redox-system/manifest.json 2>/dev/null; then
            echo FUNC_TEST:switch-gen3-description:PASS
        else
            echo "FUNC_TEST:switch-gen3-description:FAIL:description missing"
        fi
    '

    # ── Phase 10: switch forward to gen 5 (ripgrep config) ─────
    #
    # State: Gen 6 active (content of gen 3: hostname=test-rebuild-host, all pkgs)
    # Goal:  Jump to Gen 5 (packages=[ripgrep], hostname=test-rebuild-host)
    #
    # This proves:
    #   - Forward switching works (jumping to a later generation)
    #   - Package profile is correctly rebuilt (rg returns to profile)
    #   - Different package sets are correctly swapped
    echo ""
    echo "--- Phase 10: switch forward to gen 5 ---"

    /bin/snix system rollback --generation 5 > /tmp/fwd_out ^> /tmp/fwd_err
    let fwd_rc = $?

    if test $fwd_rc -eq 0
        echo "FUNC_TEST:switch-to-gen5-succeeds:PASS"
    else
        echo "FUNC_TEST:switch-to-gen5-succeeds:FAIL:exit=$fwd_rc"
        cat /tmp/fwd_out
        cat /tmp/fwd_err
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Verify rg is in the profile (gen 5 had ripgrep)
    if exists -f /nix/system/profile/bin/rg
        echo "FUNC_TEST:switch-gen5-rg-restored:PASS"
    else
        echo "FUNC_TEST:switch-gen5-rg-restored:FAIL:rg not in profile"
    end

    # Verify ripgrep is in the manifest
    /nix/system/profile/bin/rg -q ripgrep /etc/redox-system/manifest.json ^> /dev/null
    if test $? -eq 0
        echo "FUNC_TEST:switch-gen5-ripgrep-in-manifest:PASS"
    else
        echo "FUNC_TEST:switch-gen5-ripgrep-in-manifest:FAIL"
    end

    # ── Phase 10b: switch backward to gen 1 (original) ─────────
    #
    # State: Gen 7 active (content of gen 5: ripgrep, test-rebuild-host)
    # Goal:  Jump all the way back to Gen 1 (original config, all pkgs)
    #
    # This proves:
    #   - Can jump across many generations
    #   - Original system state is fully recoverable
    #   - Profile restored to initial package set (bash back, rg gone)
    echo ""
    echo "--- Phase 10b: switch back to original (gen 1) ---"

    /bin/snix system rollback --generation 1 > /tmp/orig_out ^> /tmp/orig_err
    let orig_rc = $?

    if test $orig_rc -eq 0
        echo "FUNC_TEST:switch-to-gen1-succeeds:PASS"
    else
        echo "FUNC_TEST:switch-to-gen1-succeeds:FAIL:exit=$orig_rc"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Verify hostname reverted to original
    /nix/system/profile/bin/bash -c '
        actual=$(cat /etc/hostname)
        original=$(cat /tmp/original_hostname)
        if [ "$actual" = "$original" ]; then
            echo FUNC_TEST:switch-gen1-hostname-original:PASS
        else
            echo "FUNC_TEST:switch-gen1-hostname-original:FAIL:expected $original got $actual"
        fi
    '

    # Verify bash is back in the profile (gen 1 had full packages)
    if exists -f /nix/system/profile/bin/bash
        echo "FUNC_TEST:switch-gen1-bash-restored:PASS"
    else
        echo "FUNC_TEST:switch-gen1-bash-restored:FAIL:bash not in profile"
    end

    # Verify 8 generations exist now
    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        count=$(ls "$gen_dir" 2>/dev/null | wc -l)
        if [ "$count" -ge 8 ]; then
            echo "FUNC_TEST:eight-generations-exist:PASS"
        else
            echo "FUNC_TEST:eight-generations-exist:FAIL:found $count"
        fi
    '

    # ── Phase 11: list all generations (final state) ───────────
    echo ""
    echo "--- Phase 11: generation history ---"

    /bin/snix system generations > /tmp/final_gens ^> /dev/null

    # Verify we can see all generations
    if exists -f /tmp/final_gens
        let gen_lines = $(wc -l < /tmp/final_gens)
        if test $gen_lines -ge 6
            echo "FUNC_TEST:final-generations-listed:PASS"
        else
            echo "FUNC_TEST:final-generations-listed:FAIL:only $gen_lines lines"
        end
    else
        echo "FUNC_TEST:final-generations-listed:FAIL:no output"
    end

    # Verify generation descriptions tell the story of all switches
    if exists -f /tmp/final_gens
        if grep -q "rollback to generation 3" /tmp/final_gens
            echo "FUNC_TEST:gen-history-has-switch-to-3:PASS"
        else
            echo "FUNC_TEST:gen-history-has-switch-to-3:FAIL"
        end
        if grep -q "rollback to generation 5" /tmp/final_gens
            echo "FUNC_TEST:gen-history-has-switch-to-5:PASS"
        else
            echo "FUNC_TEST:gen-history-has-switch-to-5:FAIL"
        end
        if grep -q "rollback to generation 1" /tmp/final_gens
            echo "FUNC_TEST:gen-history-has-switch-to-1:PASS"
        else
            echo "FUNC_TEST:gen-history-has-switch-to-1:FAIL"
        end
    end

    # ── Phase 12: GC root verification ───────────────────────────
    echo ""
    echo "--- Phase 12: GC root verification ---"

    # Verify per-generation GC roots exist (gen-{N}-{pkg} naming)
    /nix/system/profile/bin/bash -c '
        gcroot_dir="/nix/var/snix/gcroots"
        if [ ! -d "$gcroot_dir" ]; then
            echo "FUNC_TEST:gcroots-dir-exists:FAIL:no gcroots directory"
            exit 0
        fi
        echo FUNC_TEST:gcroots-dir-exists:PASS

        # Count gen-* roots
        gen_root_count=$(ls "$gcroot_dir" 2>/dev/null | grep "^gen-" | wc -l)
        if [ "$gen_root_count" -gt 0 ]; then
            echo "FUNC_TEST:gc-gen-roots-exist:PASS"
        else
            echo "FUNC_TEST:gc-gen-roots-exist:FAIL:no gen-* roots found"
            ls "$gcroot_dir" 2>/dev/null
        fi

        # No old system-* roots should remain
        old_roots=$(ls "$gcroot_dir" 2>/dev/null | grep "^system-" | wc -l)
        if [ "$old_roots" -eq 0 ]; then
            echo "FUNC_TEST:gc-no-system-roots:PASS"
        else
            echo "FUNC_TEST:gc-no-system-roots:FAIL:$old_roots old system-* roots remain"
        fi

        # Current generation (gen 8) should have roots
        current_roots=$(ls "$gcroot_dir" 2>/dev/null | grep "^gen-8-" | wc -l)
        if [ "$current_roots" -gt 0 ]; then
            echo "FUNC_TEST:gc-current-gen-rooted:PASS"
        else
            echo "FUNC_TEST:gc-current-gen-rooted:FAIL:no gen-8-* roots"
            ls "$gcroot_dir" 2>/dev/null | head -20
        fi

        # Earlier generations should also have roots (not deleted)
        gen1_roots=$(ls "$gcroot_dir" 2>/dev/null | grep "^gen-1-" | wc -l)
        if [ "$gen1_roots" -gt 0 ]; then
            echo "FUNC_TEST:gc-old-gen-preserved:PASS"
        else
            echo "FUNC_TEST:gc-old-gen-preserved:FAIL:gen-1 roots missing (would break rollback)"
        fi
    '

    # ── Phase 13: GC dry-run verification ─────────────────────────
    echo ""
    echo "--- Phase 13: snix system gc dry-run ---"

    # Run system gc in dry-run mode, keeping only 1 generation
    /bin/snix system gc --keep 1 --dry-run > /tmp/gc_dryrun_out ^> /tmp/gc_dryrun_err

    /nix/system/profile/bin/bash -c '
        if [ -f /tmp/gc_dryrun_out ]; then
            # Should mention pruning generations
            if grep -q "Pruning\|would delete\|generation" /tmp/gc_dryrun_out 2>/dev/null; then
                echo FUNC_TEST:gc-dryrun-output:PASS
            else
                echo "FUNC_TEST:gc-dryrun-output:FAIL:no pruning info in output"
                cat /tmp/gc_dryrun_out
                cat /tmp/gc_dryrun_err 2>/dev/null
            fi
        else
            echo "FUNC_TEST:gc-dryrun-output:FAIL:no output file"
        fi
    '

    # Verify dry-run did NOT actually delete anything
    /nix/system/profile/bin/bash -c '
        gen_dir="/etc/redox-system/generations"
        count=$(ls "$gen_dir" 2>/dev/null | wc -l)
        if [ "$count" -ge 8 ]; then
            echo "FUNC_TEST:gc-dryrun-preserves-gens:PASS"
        else
            echo "FUNC_TEST:gc-dryrun-preserves-gens:FAIL:expected >=8, found $count (dry-run deleted!)"
        fi
    '

    # Verify GC roots still intact after dry-run
    /nix/system/profile/bin/bash -c '
        gcroot_dir="/nix/var/snix/gcroots"
        gen_root_count=$(ls "$gcroot_dir" 2>/dev/null | grep "^gen-" | wc -l)
        if [ "$gen_root_count" -gt 0 ]; then
            echo "FUNC_TEST:gc-dryrun-preserves-roots:PASS"
        else
            echo "FUNC_TEST:gc-dryrun-preserves-roots:FAIL:roots gone after dry-run"
        fi
    '

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
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
      ++ opt "redox-sed"
      ++ opt "ripgrep";

    shellAliases = { };

    # Include ripgrep in the binary cache so the package addition
    # test (Phase 8) can resolve it via packages.json.
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
