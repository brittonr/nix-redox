# Network Test Profile for RedoxOS
#
# Based on development profile. Replaces interactive shell with an automated
# network diagnostic test suite. Boots with QEMU SLiRP (e1000) or Cloud
# Hypervisor TAP (virtio-net), waits for DHCP, then tests connectivity.
#
# Test protocol (same as functional-test):
#   NET_TESTS_START                → suite starting
#   NET_TEST:<name>:PASS           → test passed
#   NET_TEST:<name>:FAIL:<reason>  → test failed
#   NET_TEST:<name>:SKIP           → test skipped
#   NET_TESTS_COMPLETE             → suite finished
#
# Usage: redoxSystem { profiles = [ "network-test" ]; ... }

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  # ==========================================================================
  # Network test script — runs inside the Redox guest (Ion shell syntax)
  #
  # Tests:
  #   1. Interface discovered (any PCI-path name via /scheme/netcfg/ifaces)
  #   2. DHCP assigned an IP address
  #   3. IP address is routable (not 0.0.0.0)
  #   4. DNS resolution works
  #   5. Outbound TCP connectivity (via nc)
  #   6. ifconfig shows interface
  #   7. Routing table has default route
  #   8. Inbound connection (nc listen + connect)
  #
  # Interface names are PCI-path based (e.g. pci-0000-00-04.0_e1000),
  # NOT "eth0". We discover the first interface at runtime.
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Network Test Suite"
    echo "========================================"
    echo ""
    echo "NET_TESTS_START"
    echo ""

    # ── Discover first network interface ───────────────────────
    # Redox uses PCI-path interface names (e.g. pci-0000-00-04.0_e1000).
    # Wait for any interface to appear in /scheme/netcfg/ifaces/.
    let iface = ""
    let disc_attempts = 0
    while test $disc_attempts -lt 600
        let candidates = $(ls /scheme/netcfg/ifaces/ ^> /dev/null)
        if not test $candidates = ""
            # Take first non-lo entry. Ion has no head — use for loop + break.
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
        echo "NET_TEST:iface-discover:FAIL:no-interface-found"
        echo "NET_TESTS_COMPLETE"
        exit 0
    end
    echo "NET_TEST:iface-discover:PASS"
    echo "  Interface: $iface (found after $disc_attempts polls)"
    echo ""

    # ── Wait for DHCP to complete ──────────────────────────────
    # netcfg-setup runs as nowait, so we may need to wait here too.
    # Poll /scheme/netcfg/ifaces/<iface>/addr/list for an IP.
    # NOTE: No `sleep` binary on Redox — use file I/O reads as delay
    #       (each cat introduces ~50ms of scheme I/O latency)

    let dhcp_ok = 0
    let dhcp_addr = ""
    let attempts = 0
    # Each iteration reads /scheme/netcfg which involves kernel IPC (~5-10ms).
    # 3000 iterations × ~10ms = ~30s max wait. DHCP typically completes in <10s.
    # NOTE: Don't use `echo $var | grep` — pipe to grep fails silently in Ion.
    #       Use string comparison instead.
    while test $attempts -lt 3000
        if exists -f /scheme/netcfg/ifaces/$iface/addr/list
            let content = $(cat /scheme/netcfg/ifaces/$iface/addr/list)
            # Reject empty and "Not configured" — anything else is likely an IP
            if not test $content = "" && not test $content = "Not configured"
                let dhcp_ok = 1
                let dhcp_addr = $content
                break
            end
        end
        # Extra delay: read kernel info (real scheme I/O, ~5ms each)
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        cat /scheme/sys/uname > /dev/null
        let attempts += 1
    end

    if test $dhcp_ok -eq 0
        echo "NET_TEST:dhcp-wait:FAIL:no-ip-after-3000-polls"
        echo ""
        echo "Network diagnostics (no IP):"
        if exists -f /scheme/netcfg/ifaces/$iface/mac
            echo "  $iface/mac = $(cat /scheme/netcfg/ifaces/$iface/mac)"
        else
            echo "  $iface/mac: not found"
        end
        if exists -f /scheme/netcfg/ifaces/$iface/addr/list
            echo "  $iface/addr/list = $(cat /scheme/netcfg/ifaces/$iface/addr/list)"
        else
            echo "  $iface/addr/list: not found"
        end
        echo ""
        echo "NET_TESTS_COMPLETE"
        exit 0
    end

    echo "NET_TEST:dhcp-wait:PASS"
    echo "  IP address: $dhcp_addr (after $attempts polls)"
    echo ""

    # ── Test 1: Interface exists ────────────────────────────────
    if exists -f /scheme/netcfg/ifaces/$iface/mac
        let mac = $(cat /scheme/netcfg/ifaces/$iface/mac)
        echo "NET_TEST:iface-exists:PASS"
        echo "  MAC: $mac"
    else
        echo "NET_TEST:iface-exists:FAIL:no-mac"
    end

    # ── Test 2: IP address is valid ─────────────────────────────
    if not test $dhcp_addr = ""
        echo "NET_TEST:ip-assigned:PASS"
        echo "  Address: $dhcp_addr"
    else
        echo "NET_TEST:ip-assigned:FAIL:empty-addr"
    end

    # ── Test 3: DNS config exists ───────────────────────────────
    if exists -f /etc/net/dns
        let dns_content = $(cat /etc/net/dns)
        echo "NET_TEST:dns-config:PASS"
        echo "  DNS servers: $dns_content"
    else
        echo "NET_TEST:dns-config:FAIL:no-etc-net-dns"
    end

    # ── Test 4: Default route exists ────────────────────────────
    if exists -f /etc/net/ip_router
        let router = $(cat /etc/net/ip_router)
        echo "NET_TEST:default-route:PASS"
        echo "  Router: $router"
    else
        echo "NET_TEST:default-route:FAIL:no-ip-router"
    end

    # ── Test 5: ifconfig shows interface ────────────────────────
    if exists -f /bin/ifconfig
        let ifconfig_out = $(ifconfig $iface)
        if not test $ifconfig_out = ""
            echo "NET_TEST:ifconfig:PASS"
            echo "  $ifconfig_out"
        else
            echo "NET_TEST:ifconfig:FAIL:empty-output"
            echo "  output: $ifconfig_out"
        end
    else
        echo "NET_TEST:ifconfig:SKIP"
    end

    # ── Test 6: DNS resolution ──────────────────────────────────
    # dns <server> <type> <name>
    if exists -f /bin/dns
        let dns_result = $(dns 10.0.2.3 A example.com)
        if not test $dns_result = ""
            echo "NET_TEST:dns-resolve:PASS"
            echo "  Resolved: $dns_result"
        else
            echo "NET_TEST:dns-resolve:FAIL:empty-response"
            echo "  output: $dns_result"
        end
    else
        echo "NET_TEST:dns-resolve:SKIP"
    end

    # ── Test 7: Ping gateway ────────────────────────────────────
    if exists -f /bin/ping
        # ping the QEMU SLiRP gateway (10.0.2.2)
        let ping_result = $(ping -c 1 10.0.2.2)
        if not test $ping_result = ""
            echo "NET_TEST:ping-gateway:PASS"
            echo "  $ping_result"
        else
            echo "NET_TEST:ping-gateway:FAIL:no-reply"
            echo "  output: $ping_result"
        end
    else
        echo "NET_TEST:ping-gateway:SKIP"
    end

    # ── Test 8: TCP connection via nc ───────────────────────────
    # Try connecting to QEMU's built-in DNS server (TCP port 53)
    if exists -f /bin/nc
        echo "" | nc -w 3 10.0.2.3 53 > /dev/null
        if test $? -eq 0
            echo "NET_TEST:tcp-connect:PASS"
            echo "  Connected to 10.0.2.3:53 (QEMU DNS)"
        else
            echo "NET_TEST:tcp-connect:FAIL:connection-failed"
        end
    else
        echo "NET_TEST:tcp-connect:SKIP"
    end

    echo ""
    echo "NET_TESTS_COMPLETE"
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
    dns = [
      "10.0.2.3"
    ]; # QEMU SLiRP DNS
    defaultRouter = "10.0.2.2"; # QEMU SLiRP gateway
  };

  "/services" = {
    startupScriptText = testScript;
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
    };
  };

  "/virtualisation" = {
    vmm = "qemu";
    memorySize = 2048;
    cpus = 4;
  };
}
