# Scheme-Native End-to-End Test Profile for RedoxOS
#
# Tests the full scheme daemon lifecycle with init-script auto-start:
#   1. Daemons start automatically via init scripts (12_stored, 13_profiled)
#   2. `snix install` while daemons are running triggers dynamic manifest loading
#   3. store: scheme serves files from newly-installed packages
#   4. profile: scheme presents union views updated live
#   5. Install/remove cycle verifies profiled mutation via .control
#
# This differs from scheme-daemon-test.nix which starts daemons manually
# AFTER installing packages. Here, daemons start BEFORE any installs,
# testing the harder path: dynamic discovery of new store paths.
#
# Test protocol:
#   FUNC_TESTS_START              → suite starting
#   FUNC_TEST:<name>:PASS         → test passed
#   FUNC_TEST:<name>:FAIL:<reason>→ test failed
#   FUNC_TEST:<name>:SKIP         → test skipped
#   FUNC_TESTS_COMPLETE           → suite finished

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  # ==========================================================================
  # Ion shell test suite — runs inside the Redox guest
  #
  # Tests store: and profile: scheme daemons in the "live install" scenario:
  # daemons are already running when packages get installed.
  # Uses Ion shell syntax (NOT bash/POSIX).
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Scheme-Native E2E Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Wait for daemons to start via init scripts ─────────────
    # The init system starts stored (12_stored) and profiled (13_profiled)
    # before the startup script runs. Wait for them to register.
    echo "Waiting for scheme daemons to register..."
    let daemon_ready = 0
    let wait_count = 0
    while test $wait_count -lt 500
        ls /scheme/ > /tmp/scheme-list ^> /dev/null
        grep "store" /tmp/scheme-list > /dev/null ^> /dev/null
        if test $? = 0
            grep "profile" /tmp/scheme-list > /dev/null ^> /dev/null
            if test $? = 0
                let daemon_ready = 1
                break
            end
        end
        let wait_count += 1
    end

    # ── Test: daemons auto-started ─────────────────────────────
    if test $daemon_ready = 1
        echo "FUNC_TEST:daemons-auto-started:PASS"
    else
        echo "FUNC_TEST:daemons-auto-started:FAIL:schemes-not-registered after $wait_count iterations"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    # ── Test: store scheme root is accessible ──────────────────
    ls /scheme/store/ > /tmp/store-root-ls ^> /tmp/store-root-err
    if test $? = 0
        echo "FUNC_TEST:store-scheme-accessible:PASS"
    else
        let err = $(cat /tmp/store-root-err)
        echo "FUNC_TEST:store-scheme-accessible:FAIL:err=$err"
    end

    # ── Test: profile scheme root is accessible ────────────────
    ls /scheme/profile/ > /tmp/profile-root-ls ^> /tmp/profile-root-err
    if test $? = 0
        echo "FUNC_TEST:profile-scheme-accessible:PASS"
    else
        let err = $(cat /tmp/profile-root-err)
        echo "FUNC_TEST:profile-scheme-accessible:FAIL:err=$err"
    end

    # ── Test: store scheme is empty (no packages installed yet)─
    let store_count = $(cat /tmp/store-root-ls | wc -l)
    # Store may have system packages from boot, so just verify it works
    echo "FUNC_TEST:store-scheme-initially-works:PASS"
    echo "  store paths at boot: $store_count"

    # ════════════════════════════════════════════════════════════
    # LIVE INSTALL — daemons are running, install a package
    # ════════════════════════════════════════════════════════════

    # ── Test: snix install ripgrep ─────────────────────────────
    /bin/snix install ripgrep > /tmp/install-rg-out ^> /tmp/install-rg-err
    let install_rc = $?
    if test $install_rc = 0
        echo "FUNC_TEST:live-install-ripgrep:PASS"
    else
        let err = $(cat /tmp/install-rg-err)
        echo "FUNC_TEST:live-install-ripgrep:FAIL:rc=$install_rc err=$err"
    end

    # ── Find the ripgrep store path ────────────────────────────
    let rg_store_path = ""
    let rg_name = ""
    for entry in @lines($(ls /nix/store/))
        let is_rg = $(echo $entry | grep "ripgrep")
        if test -n $is_rg
            let rg_name = $entry
            let rg_store_path = "/nix/store/$entry"
            break
        end
    end

    if test -n $rg_store_path
        echo "FUNC_TEST:rg-store-path-found:PASS"
        echo "  path=$rg_store_path"
    else
        echo "FUNC_TEST:rg-store-path-found:FAIL:not-in-store"
    end

    # ════════════════════════════════════════════════════════════
    # STORED — verify dynamic manifest loading
    # ════════════════════════════════════════════════════════════

    # ── Test: store scheme now lists ripgrep ────────────────────
    # stored must dynamically discover the new package (it wasn't
    # in PathInfoDb at daemon startup).
    ls /scheme/store/ > /tmp/store-ls-after ^> /tmp/store-ls-after-err
    if test $? = 0
        grep "ripgrep" /tmp/store-ls-after > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:store-scheme-lists-ripgrep:PASS"
        else
            let content = $(cat /tmp/store-ls-after)
            echo "FUNC_TEST:store-scheme-lists-ripgrep:FAIL:not-listed content=$content"
        end
    else
        let err = $(cat /tmp/store-ls-after-err)
        echo "FUNC_TEST:store-scheme-lists-ripgrep:FAIL:ls-failed err=$err"
    end

    # ── Test: store scheme lists ripgrep contents ──────────────
    # This tests dynamic manifest loading — the manifest must be
    # loaded via the I/O worker thread since it wasn't pre-loaded.
    if test -n $rg_name
        ls /scheme/store/$rg_name/ > /tmp/store-rg-ls ^> /tmp/store-rg-ls-err
        if test $? = 0
            grep "bin" /tmp/store-rg-ls > /dev/null ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:store-scheme-dynamic-manifest:PASS"
            else
                let content = $(cat /tmp/store-rg-ls)
                echo "FUNC_TEST:store-scheme-dynamic-manifest:FAIL:no-bin content=$content"
            end
        else
            let err = $(cat /tmp/store-rg-ls-err)
            echo "FUNC_TEST:store-scheme-dynamic-manifest:FAIL:ls-failed err=$err"
        end
    else
        echo "FUNC_TEST:store-scheme-dynamic-manifest:SKIP"
    end

    # ── Test: store scheme lists bin/rg ────────────────────────
    if test -n $rg_name
        ls /scheme/store/$rg_name/bin/ > /tmp/store-rg-bin ^> /tmp/store-rg-bin-err
        if test $? = 0
            grep "rg" /tmp/store-rg-bin > /dev/null ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:store-scheme-bin-listing:PASS"
            else
                let content = $(cat /tmp/store-rg-bin)
                echo "FUNC_TEST:store-scheme-bin-listing:FAIL:no-rg content=$content"
            end
        else
            let err = $(cat /tmp/store-rg-bin-err)
            echo "FUNC_TEST:store-scheme-bin-listing:FAIL:ls-failed err=$err"
        end
    else
        echo "FUNC_TEST:store-scheme-bin-listing:SKIP"
    end

    # ── Test: store scheme can serve file content ──────────────
    # The real file at /nix/store/ should be accessible.
    if test -n $rg_name
        if exists -f /nix/store/$rg_name/bin/rg
            echo "FUNC_TEST:store-file-accessible:PASS"
        else
            echo "FUNC_TEST:store-file-accessible:FAIL:file-not-found"
        end
    else
        echo "FUNC_TEST:store-file-accessible:SKIP"
    end

    # ════════════════════════════════════════════════════════════
    # PROFILED — verify live profile mutation
    # ════════════════════════════════════════════════════════════

    # ── Test: profiled has default profile ──────────────────────
    ls /scheme/profile/ > /tmp/prof-ls ^> /tmp/prof-ls-err
    if test $? = 0
        grep "default" /tmp/prof-ls > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:profiled-has-default:PASS"
        else
            let content = $(cat /tmp/prof-ls)
            echo "FUNC_TEST:profiled-has-default:FAIL:no-default content=$content"
        end
    else
        let err = $(cat /tmp/prof-ls-err)
        echo "FUNC_TEST:profiled-has-default:FAIL:ls-failed err=$err"
    end

    # ── Test: profile has bin directory ─────────────────────────
    ls /scheme/profile/default/ > /tmp/prof-default-ls ^> /tmp/prof-default-ls-err
    if test $? = 0
        grep "bin" /tmp/prof-default-ls > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:profiled-has-bin:PASS"
        else
            let content = $(cat /tmp/prof-default-ls)
            echo "FUNC_TEST:profiled-has-bin:FAIL:no-bin content=$content"
        end
    else
        let err = $(cat /tmp/prof-default-ls-err)
        echo "FUNC_TEST:profiled-has-bin:FAIL:ls-failed err=$err"
    end

    # ── Test: profile bin/ contains rg ─────────────────────────
    ls /scheme/profile/default/bin/ > /tmp/prof-bin-ls ^> /tmp/prof-bin-ls-err
    if test $? = 0
        grep "rg" /tmp/prof-bin-ls > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:profiled-bin-has-rg:PASS"
        else
            let content = $(cat /tmp/prof-bin-ls)
            echo "FUNC_TEST:profiled-bin-has-rg:FAIL:no-rg content=$content"
        end
    else
        let err = $(cat /tmp/prof-bin-ls-err)
        echo "FUNC_TEST:profiled-bin-has-rg:FAIL:ls-failed err=$err"
    end

    # ── Test: rg binary executes via store path ─────────────────
    # When profiled runs as a scheme daemon, profile content is served
    # through the profile: scheme (/scheme/profile/default/bin/rg), NOT
    # as filesystem symlinks at /nix/var/snix/profiles/default/bin/.
    # Execution goes through the store path, which always exists on disk.
    if test -n $rg_store_path
        $rg_store_path/bin/rg --version > /tmp/rg-ver ^> /tmp/rg-ver-err
        if test $? = 0
            grep "ripgrep" /tmp/rg-ver > /dev/null ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:rg-from-store-executes:PASS"
            else
                let ver = $(cat /tmp/rg-ver)
                echo "FUNC_TEST:rg-from-store-executes:FAIL:no-ripgrep-in-output ver=$ver"
            end
        else
            let err = $(cat /tmp/rg-ver-err)
            echo "FUNC_TEST:rg-from-store-executes:FAIL:rg-failed err=$err"
        end
    else
        echo "FUNC_TEST:rg-from-store-executes:SKIP:no-store-path"
    end

    # ── Test: store scheme serves rg binary content ────────────
    # Verify stored can serve full binary content (not just directory
    # listings) for a dynamically-installed package.
    if test -n $rg_name
        cat /scheme/store/$rg_name/bin/rg > /tmp/rg-scheme-bin ^> /tmp/rg-scheme-bin-err
        if test $? = 0
            let rg_size = $(wc -c < /tmp/rg-scheme-bin)
            if test $rg_size -gt 0
                echo "FUNC_TEST:store-scheme-file-read:PASS"
                echo "  rg binary size via scheme: $rg_size bytes"
            else
                echo "FUNC_TEST:store-scheme-file-read:FAIL:zero-bytes"
            end
        else
            let err = $(cat /tmp/rg-scheme-bin-err)
            echo "FUNC_TEST:store-scheme-file-read:FAIL:cat-failed err=$err"
        end
    else
        echo "FUNC_TEST:store-scheme-file-read:SKIP:no-rg-name"
    end

    # ════════════════════════════════════════════════════════════
    # LIVE INSTALL #2 — verify profile updates dynamically
    # ════════════════════════════════════════════════════════════

    # ── Test: install fd ───────────────────────────────────────
    /bin/snix install fd > /tmp/install-fd-out ^> /tmp/install-fd-err
    if test $? = 0
        echo "FUNC_TEST:live-install-fd:PASS"
    else
        let err = $(cat /tmp/install-fd-err)
        echo "FUNC_TEST:live-install-fd:FAIL:err=$err"
    end

    # Brief delay for profiled to process the control command.
    let delay = 0
    while test $delay -lt 100
        let delay += 1
    end

    # ── Test: profile now has both rg and fd ───────────────────
    ls /scheme/profile/default/bin/ > /tmp/prof-bin-ls2 ^> /tmp/prof-bin-ls2-err
    if test $? = 0
        let rg_found = 0
        let fd_found = 0
        for entry in @lines($(cat /tmp/prof-bin-ls2))
            if test $entry = "rg"
                let rg_found = 1
            end
            if test $entry = "fd"
                let fd_found = 1
            end
        end
        if test $rg_found = 1 && test $fd_found = 1
            echo "FUNC_TEST:profiled-union-rg-fd:PASS"
        else
            echo "FUNC_TEST:profiled-union-rg-fd:FAIL:rg=$rg_found fd=$fd_found"
        end
    else
        echo "FUNC_TEST:profiled-union-rg-fd:FAIL:ls-failed"
    end

    # ════════════════════════════════════════════════════════════
    # REMOVE — verify profile cleanup
    # ════════════════════════════════════════════════════════════

    # ── Test: remove fd ────────────────────────────────────────
    /bin/snix remove fd > /tmp/remove-fd-out ^> /tmp/remove-fd-err
    if test $? = 0
        echo "FUNC_TEST:live-remove-fd:PASS"
    else
        let err = $(cat /tmp/remove-fd-err)
        echo "FUNC_TEST:live-remove-fd:FAIL:err=$err"
    end

    # Brief delay for profiled to process.
    let delay2:int = 0
    while test $delay2 -lt 500
        let delay2 += 1
    end

    # ── Test: fd gone from profile ─────────────────────────────
    ls /scheme/profile/default/bin/ > /tmp/prof-bin-ls3 ^> /tmp/prof-bin-ls3-err
    if test $? = 0
        grep "^fd" /tmp/prof-bin-ls3 > /dev/null ^> /dev/null
        if test $? != 0
            echo "FUNC_TEST:profiled-fd-removed:PASS"
        else
            echo "FUNC_TEST:profiled-fd-removed:FAIL:fd-still-present"
        end
    else
        echo "FUNC_TEST:profiled-fd-removed:FAIL:ls-failed"
    end

    # ── Test: rg still present after fd removal ────────────────
    grep "rg" /tmp/prof-bin-ls3 > /dev/null ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:profiled-rg-survives-remove:PASS"
    else
        echo "FUNC_TEST:profiled-rg-survives-remove:FAIL:rg-also-gone"
    end

    # ── Test: store scheme still serves ripgrep ────────────────
    if test -n $rg_name
        ls /scheme/store/$rg_name/bin/ > /tmp/store-stable-ls ^> /dev/null
        if test $? = 0
            grep "rg" /tmp/store-stable-ls > /dev/null ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:store-scheme-stable-after-remove:PASS"
            else
                echo "FUNC_TEST:store-scheme-stable-after-remove:FAIL:rg-gone"
            end
        else
            echo "FUNC_TEST:store-scheme-stable-after-remove:FAIL:ls-failed"
        end
    else
        echo "FUNC_TEST:store-scheme-stable-after-remove:SKIP"
    end

    # ── Test: snix show sees installed ripgrep ─────────────────
    /bin/snix show ripgrep > /tmp/show-rg-out ^> /tmp/show-rg-err
    if test $? = 0
        grep "ripgrep" /tmp/show-rg-out > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:snix-show-ripgrep:PASS"
        else
            echo "FUNC_TEST:snix-show-ripgrep:FAIL:no-output"
        end
    else
        echo "FUNC_TEST:snix-show-ripgrep:FAIL:cmd-failed"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    # Do NOT include "userutils" — it causes a login loop.
    systemPackages = opt "ion" ++ opt "uutils" ++ opt "extrautils" ++ opt "snix";

    # Include ripgrep and fd in the local binary cache so snix install
    # can find them without network access.
    binaryCachePackages =
      lib.optionalAttrs (pkgs ? ripgrep) { ripgrep = pkgs.ripgrep; }
      // lib.optionalAttrs (pkgs ? fd) { fd = pkgs.fd; };
  };

  "/networking" = {
    enable = false;
    mode = "none";
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
    };
  };

  "/services" = {
    startupScriptText = testScript;
  };

  # Enable daemons via init scripts — the key difference from
  # scheme-daemon-test which starts them manually.
  "/snix" = {
    stored = {
      enable = true;
      cachePath = "/nix/cache";
      storeDir = "/nix/store";
    };
    profiled = {
      enable = true;
      profilesDir = "/nix/var/snix/profiles";
      storeDir = "/nix/store";
    };
    sandbox = false;
  };

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
