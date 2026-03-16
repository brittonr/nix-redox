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

    # Rebuild with package change
    /bin/snix system rebuild > /tmp/pkg_rebuild_out ^> /tmp/pkg_rebuild_err

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
