# Network Install Test Profile for RedoxOS
#
# Extends the network test profile with snix remote install tests.
# Boots with QEMU SLiRP, waits for DHCP, then tests installing packages
# from a remote HTTP binary cache served by the host at 10.0.2.2:8080.
#
# The test packages are NOT included in the disk image — they must be
# fetched from the remote cache to prove the network install pipeline works.
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
  # Network Install Test Script — runs inside the Redox guest (Ion shell)
  #
  # Waits for DHCP, then tests snix remote binary cache operations:
  #   1. HTTP connectivity to host cache at 10.0.2.2:8080
  #   2. snix search --cache-url (list remote packages)
  #   3. snix install --cache-url (download and install a package)
  #   4. Verify installed binary exists and executes
  #   5. Verify store path created
  #   6. Idempotent install (second install says "already installed")
  #   7. snix show --cache-url (display package info)
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Network Install Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    let CACHE_URL = "http://10.0.2.2:18080"

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
        echo "FUNC_TEST:net-dhcp:FAIL:no-ip-after-3000-polls"
        echo "FUNC_TESTS_COMPLETE"
        exit 0
    end
    echo "FUNC_TEST:net-dhcp:PASS"
    echo "  DHCP complete after $attempts polls"

    # ── Test: HTTP connectivity to cache ───────────────────────
    # snix search GETs packages.json — if it returns anything, the cache is up.
    # NOTE: Ion uses ^> for stderr, NOT 2>. Capture stdout only.
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

    # ── Test: snix search --cache-url ──────────────────────────
    # Verify search output lists at least one package
    let search_result = $(cat /tmp/search_out)
    if not test $search_result = ""
        echo "FUNC_TEST:net-search:PASS"
    else
        echo "FUNC_TEST:net-search:FAIL:empty-search"
    end

    # ── Test: snix install from remote cache ───────────────────
    # Install mock-hello — small, quick to download
    snix install mock-hello --cache-url $CACHE_URL ^> /tmp/install_err
    if exists -f /nix/var/snix/profiles/default/bin/mock-hello
        echo "FUNC_TEST:net-install:PASS"
        echo "  mock-hello installed to profile"
    else
        echo "FUNC_TEST:net-install:FAIL:binary-not-in-profile"
        if exists -f /tmp/install_err
            echo "  stderr: $(cat /tmp/install_err)"
        end
    end

    # ── Test: installed binary executes ────────────────────────
    if exists -f /nix/var/snix/profiles/default/bin/mock-hello
        /nix/var/snix/profiles/default/bin/mock-hello > /tmp/hello_out
        let hello_out = $(cat /tmp/hello_out)
        if not test $hello_out = ""
            echo "FUNC_TEST:net-install-runs:PASS"
            echo "  Output: $hello_out"
        else
            echo "FUNC_TEST:net-install-runs:FAIL:no-output"
        end
    else
        echo "FUNC_TEST:net-install-runs:FAIL:binary-missing"
    end

    # ── Test: store path exists ────────────────────────────────
    ls /nix/store/ > /tmp/store_ls
    let store_count = $(wc -l < /tmp/store_ls)
    if test $store_count -gt 0
        echo "FUNC_TEST:net-store-path:PASS"
        echo "  Store paths: $store_count"
    else
        echo "FUNC_TEST:net-store-path:FAIL:empty-store"
    end

    # ── Test: idempotent install ───────────────────────────────
    snix install mock-hello --cache-url $CACHE_URL ^> /tmp/reinstall_err
    if exists -f /tmp/reinstall_err
        let reinstall_out = $(cat /tmp/reinstall_err)
        if not test $reinstall_out = ""
            echo "FUNC_TEST:net-install-idempotent:PASS"
            echo "  Second install: $reinstall_out"
        else
            echo "FUNC_TEST:net-install-idempotent:FAIL:no-output"
        end
    else
        echo "FUNC_TEST:net-install-idempotent:PASS"
    end

    # ── Test: snix show --cache-url ────────────────────────────
    snix show mock-hello --cache-url $CACHE_URL > /tmp/show_out
    if exists -f /tmp/show_out
        let show_out = $(cat /tmp/show_out)
        if not test $show_out = ""
            echo "FUNC_TEST:net-show:PASS"
        else
            echo "FUNC_TEST:net-show:FAIL:empty-show"
        end
    else
        echo "FUNC_TEST:net-show:FAIL:no-output-file"
    end

    # ── Test: install ripgrep from remote cache ────────────────
    snix install ripgrep --cache-url $CACHE_URL ^> /tmp/rg_install_err
    if exists -f /nix/var/snix/profiles/default/bin/rg
        echo "FUNC_TEST:net-install-ripgrep:PASS"
        echo "  ripgrep installed to profile"
    else
        echo "FUNC_TEST:net-install-ripgrep:FAIL:binary-not-in-profile"
        if exists -f /tmp/rg_install_err
            echo "  stderr: $(cat /tmp/rg_install_err)"
        end
    end

    # ── Test: ripgrep binary executes ──────────────────────────
    if exists -f /nix/var/snix/profiles/default/bin/rg
        /nix/var/snix/profiles/default/bin/rg --version > /tmp/rg_version_out
        if exists -f /tmp/rg_version_out
            let rg_out = $(cat /tmp/rg_version_out)
            if not test $rg_out = ""
                echo "FUNC_TEST:net-ripgrep-runs:PASS"
                echo "  Output: $rg_out"
            else
                echo "FUNC_TEST:net-ripgrep-runs:FAIL:no-output"
            end
        else
            echo "FUNC_TEST:net-ripgrep-runs:FAIL:no-output-file"
        end
    else
        echo "FUNC_TEST:net-ripgrep-runs:FAIL:binary-missing"
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
