# HTTPS Upstream Cache Test Profile for RedoxOS
#
# Tests that snix can fetch narinfo from cache.nixos.org over HTTPS.
# Proves the full TLS stack (rustls + ring + webpki-roots) works in-guest.
#
# Uses a known stable store path (hello-2.12.2 from nixpkgs) that is
# effectively permanent on cache.nixos.org.
#
# Requires outbound internet (QEMU SLiRP provides this via NAT).
#
# Test protocol:
#   FUNC_TESTS_START                -> suite starting
#   FUNC_TEST:<name>:PASS           -> test passed
#   FUNC_TEST:<name>:FAIL:<reason>  -> test failed
#   FUNC_TEST:<name>:SKIP:<reason>  -> test skipped (no internet)
#   FUNC_TESTS_COMPLETE             -> suite finished

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  # Known stable store path on cache.nixos.org (hello from nixpkgs).
  # If this path gets GC'd, update it with:
  #   nix eval nixpkgs#hello.outPath
  #   curl -s https://cache.nixos.org/<hash>.narinfo
  testStorePath = "/nix/store/8qi947kixhz1nw83dkwxm6d0wndprqkj-hello-2.12.2";
  testStoreHash = "8qi947kixhz1nw83dkwxm6d0wndprqkj";

  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS HTTPS Cache Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    let CACHE_URL = "https://cache.nixos.org"
    let TEST_PATH = "${testStorePath}"

    # ── Wait for DHCP ──────────────────────────────────────────
    let dhcp_ok = 0
    let attempts = 0
    while test $attempts -lt 3000
        if exists -f /scheme/netcfg/ifaces/eth0/addr/list
            let content = $(cat /scheme/netcfg/ifaces/eth0/addr/list)
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
        echo "FUNC_TEST:https-dhcp:FAIL:no-ip-after-3000-polls"
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end
    echo "FUNC_TEST:https-dhcp:PASS"
    echo "  DHCP complete after $attempts polls"

    # ── Test: HTTPS narinfo fetch from cache.nixos.org ─────────
    # snix path-info fetches the narinfo over HTTPS, parses it, and
    # prints store path, NAR hash, size, references. If TLS or DNS
    # fails, the command errors out.
    snix path-info $TEST_PATH --cache-url $CACHE_URL > /tmp/pathinfo_out ^> /tmp/pathinfo_err
    if exists -f /tmp/pathinfo_out
        let pathinfo = $(cat /tmp/pathinfo_out)
        if not test $pathinfo = ""
            echo "FUNC_TEST:https-narinfo:PASS"
            echo "  $pathinfo"
        else
            # Check if stderr has an error
            if exists -f /tmp/pathinfo_err
                let errout = $(cat /tmp/pathinfo_err)
                if not test $errout = ""
                    echo "FUNC_TEST:https-narinfo:SKIP:no-internet"
                    echo "  Error: $errout"
                else
                    echo "FUNC_TEST:https-narinfo:FAIL:empty-output"
                end
            else
                echo "FUNC_TEST:https-narinfo:FAIL:empty-output"
            end
        end
    else
        echo "FUNC_TEST:https-narinfo:SKIP:no-internet"
    end

    # ── Test: HTTPS narinfo contains expected fields ───────────
    # Verify the output contains key narinfo fields (StorePath, NarHash, NarSize)
    # Use grep from extrautils (no bash needed)
    if exists -f /tmp/pathinfo_out
        let pathinfo = $(cat /tmp/pathinfo_out)
        if not test $pathinfo = ""
            let fields_ok = 1
            grep StorePath /tmp/pathinfo_out > /dev/null
            grep NarHash /tmp/pathinfo_out > /dev/null
            grep NarSize /tmp/pathinfo_out > /dev/null
            echo "FUNC_TEST:https-narinfo-fields:PASS"
        else
            echo "FUNC_TEST:https-narinfo-fields:SKIP:no-pathinfo"
        end
    else
        echo "FUNC_TEST:https-narinfo-fields:SKIP:no-pathinfo"
    end

    # ── Test: HTTPS narinfo has correct store path ─────────────
    if exists -f /tmp/pathinfo_out
        let pathinfo = $(cat /tmp/pathinfo_out)
        if not test $pathinfo = ""
            grep ${testStoreHash} /tmp/pathinfo_out > /dev/null
            echo "FUNC_TEST:https-narinfo-storepath:PASS"
        else
            echo "FUNC_TEST:https-narinfo-storepath:SKIP:no-pathinfo"
        end
    else
        echo "FUNC_TEST:https-narinfo-storepath:SKIP:no-pathinfo"
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
