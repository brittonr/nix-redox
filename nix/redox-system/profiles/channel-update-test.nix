# Channel Update Test Profile for RedoxOS
#
# Boots with QEMU SLiRP networking, registers a channel pointing to the
# host HTTP cache at 10.0.2.2:18080, fetches the channel manifest, then
# runs `snix system upgrade --yes` to verify the full channel pipeline.
#
# The host serves a "channel manifest" that has one extra package compared
# to the on-disk system manifest. The upgrade fetches that package from the
# binary cache, creates a new generation, and updates the manifest.
#
# Test protocol:
#   FUNC_TESTS_START                → suite starting
#   FUNC_TEST:<name>:PASS           → test passed
#   FUNC_TEST:<name>:FAIL:<reason>  → test failed
#   FUNC_TESTS_COMPLETE             → suite finished

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  # ==========================================================================
  # Channel Update Test Script — runs inside the Redox guest (Ion shell)
  #
  # Waits for DHCP, then tests the channel update → upgrade pipeline:
  #   1. HTTP connectivity (DHCP + cache reachable)
  #   2. snix channel add (register a channel)
  #   3. snix channel list (verify registration)
  #   4. snix channel update (fetch manifest from HTTP)
  #   5. snix system upgrade --yes (create new generation)
  #   6. Verify new generation created
  #   7. Idempotent second upgrade (already up to date)
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Channel Update Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    let CACHE_URL = "http://10.0.2.2:18080"
    let CHANNEL_NAME = "test-channel"

    # ── Discover first interface + wait for DHCP ─────────────────
    # Redox uses PCI-path interface names (e.g. pci-0000-00-04.0_e1000).
    let iface = ""
    let disc_attempts = 0
    while test $disc_attempts -lt 600
        let candidates = $(ls /scheme/netcfg/ifaces/ ^> /dev/null)
        if not test $candidates = ""
            for name in @split(candidates)
                if not test $name = "lo"
                    let iface = $name
                    break
                end
            end
            if not test $iface = ""
                break
            end
        end
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        let disc_attempts += 1
    end

    if test $iface = ""
        echo "FUNC_TEST:net-dhcp:FAIL:no-interface-found"
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end

    let dhcp_ok = 0
    let attempts = 0
    while test $attempts -lt 3000
        if exists -f /scheme/netcfg/ifaces/$iface/addr/list
            let content = $(cat /scheme/netcfg/ifaces/$iface/addr/list)
            if not test $content = "" && not test $content = "Not configured"
                let dhcp_ok = 1
                break
            end
        end
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        let attempts += 1
    end

    if test $dhcp_ok -eq 0
        echo "FUNC_TEST:net-dhcp:FAIL:no-ip-after-3000-polls"
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end
    echo "FUNC_TEST:net-dhcp:PASS"
    echo "  Interface: $iface — DHCP complete after $attempts polls"

    # ── Test: HTTP connectivity to cache ───────────────────────
    snix search --cache-url $CACHE_URL > /tmp/search_out
    if exists -f /tmp/search_out
        let search_out = $(cat /tmp/search_out)
        if not test $search_out = ""
            echo "FUNC_TEST:net-connectivity:PASS"
            echo "  Cache reachable at $CACHE_URL"
        else
            echo "FUNC_TEST:net-connectivity:FAIL:cache-unreachable"
            echo "FUNC_TESTS_COMPLETE"
            exit 0
        end
    else
        echo "FUNC_TEST:net-connectivity:FAIL:no-output-file"
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end

    # ── Test: snix channel add ─────────────────────────────────
    snix channel add $CHANNEL_NAME $CACHE_URL ^> /tmp/ch_add_err
    if exists -d /nix/var/snix/channels/$CHANNEL_NAME
        echo "FUNC_TEST:channel-add:PASS"
        echo "  Channel dir created"
    else
        echo "FUNC_TEST:channel-add:FAIL:dir-not-created"
        if exists -f /tmp/ch_add_err
            echo "  stderr: $(cat /tmp/ch_add_err)"
        end
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end

    # ── Test: channel URL file exists ──────────────────────────
    if exists -f /nix/var/snix/channels/$CHANNEL_NAME/url
        let url_content = $(cat /nix/var/snix/channels/$CHANNEL_NAME/url)
        if not test $url_content = ""
            echo "FUNC_TEST:channel-url:PASS"
            echo "  URL: $url_content"
        else
            echo "FUNC_TEST:channel-url:FAIL:url-empty"
        end
    else
        echo "FUNC_TEST:channel-url:FAIL:url-file-missing"
    end

    # ── Test: snix channel list ────────────────────────────────
    snix channel list > /tmp/ch_list_out
    if exists -f /tmp/ch_list_out
        let list_out = $(cat /tmp/ch_list_out)
        if not test $list_out = ""
            echo "FUNC_TEST:channel-list:PASS"
        else
            echo "FUNC_TEST:channel-list:FAIL:empty-output"
        end
    else
        echo "FUNC_TEST:channel-list:FAIL:no-output-file"
    end

    # ── Test: snix channel update ──────────────────────────────
    snix channel update $CHANNEL_NAME ^> /tmp/ch_update_err
    if exists -f /nix/var/snix/channels/$CHANNEL_NAME/manifest.json
        echo "FUNC_TEST:channel-update:PASS"
        echo "  Manifest fetched"
    else
        echo "FUNC_TEST:channel-update:FAIL:no-manifest"
        if exists -f /tmp/ch_update_err
            echo "  stderr: $(cat /tmp/ch_update_err)"
        end
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end

    # ── Test: last-fetched timestamp written ───────────────────
    if exists -f /nix/var/snix/channels/$CHANNEL_NAME/last-fetched
        let ts = $(cat /nix/var/snix/channels/$CHANNEL_NAME/last-fetched)
        if not test $ts = ""
            echo "FUNC_TEST:channel-timestamp:PASS"
            echo "  Timestamp: $ts"
        else
            echo "FUNC_TEST:channel-timestamp:FAIL:empty"
        end
    else
        echo "FUNC_TEST:channel-timestamp:FAIL:file-missing"
    end

    # ── Count generations before upgrade ───────────────────────
    ls /etc/redox-system/generations/ > /tmp/gens_before
    let gens_before = $(wc -l < /tmp/gens_before)
    echo "  Generations before upgrade: $gens_before"

    # ── Test: snix system upgrade ──────────────────────────────
    snix system upgrade --yes -m /etc/redox-system/manifest.json ^> /tmp/upgrade_err > /tmp/upgrade_out
    let upgrade_out = ""
    if exists -f /tmp/upgrade_out
        let upgrade_out = $(cat /tmp/upgrade_out)
    end
    let upgrade_err = ""
    if exists -f /tmp/upgrade_err
        let upgrade_err = $(cat /tmp/upgrade_err)
    end

    # Check if new generation was created
    ls /etc/redox-system/generations/ > /tmp/gens_after
    let gens_after = $(wc -l < /tmp/gens_after)

    if test $gens_after -gt $gens_before
        echo "FUNC_TEST:system-upgrade:PASS"
        echo "  Generations: $gens_before -> $gens_after"
        echo "  Output: $upgrade_out"
    else
        # Might be "already up to date" if manifests match
        # Check if the output says so
        echo "FUNC_TEST:system-upgrade:FAIL:no-new-generation"
        echo "  stdout: $upgrade_out"
        echo "  stderr: $upgrade_err"
        echo "  gens before=$gens_before after=$gens_after"
    end

    # ── Test: idempotent second upgrade ────────────────────────
    snix system upgrade --yes -m /etc/redox-system/manifest.json > /tmp/upgrade2_out ^> /tmp/upgrade2_err

    ls /etc/redox-system/generations/ > /tmp/gens_after2
    let gens_after2 = $(wc -l < /tmp/gens_after2)

    if test $gens_after2 -eq $gens_after
        echo "FUNC_TEST:upgrade-idempotent:PASS"
        echo "  No new generation on second upgrade"
    else
        echo "FUNC_TEST:upgrade-idempotent:FAIL:extra-generation"
        echo "  gens after first=$gens_after after second=$gens_after2"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
  '';
in

{
  "/environment" = {
    systemPackages =
      opt "ion" ++ opt "uutils" ++ opt "extrautils" ++ opt "netutils" ++ opt "netcfg-setup" ++ opt "snix";
  };

  "/networking" = {
    enable = true;
    mode = "auto";
    dns = [ "10.0.2.3" ];
    defaultRouter = "10.0.2.2";
  };

  "/services" = {
    startupScriptText = testScript;
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
    };
  };

  "/boot" = {
    diskSizeMB = 768;
  };

  "/virtualisation" = {
    vmm = "qemu";
    memorySize = 2048;
    cpus = 4;
  };
}
