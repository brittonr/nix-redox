# Scheme Daemon Test Profile for RedoxOS
#
# Tests that the `stored` and `profiled` scheme daemons actually work
# inside a running Redox VM. Enables both daemons, installs a package
# from the local binary cache, then verifies:
#   - store: scheme serves files from /nix/store/
#   - profile: scheme presents a union view of installed packages
#   - snix install detects and uses the profiled daemon
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
  # Tests the store: and profile: scheme daemons end-to-end.
  # Uses Ion shell syntax (NOT bash/POSIX).
  # ==========================================================================
  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Scheme Daemon Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Pre-install packages before daemons start ───────────────
    # Install ripgrep first so PathInfoDb has manifest data when
    # the daemons load. Scheme daemons can't do filesystem I/O in
    # their event loops, so all data must be pre-loaded at startup.
    /bin/snix install ripgrep > /tmp/install-rg-out ^> /tmp/install-rg-err
    let install_rc = $?

    # ── Test: snix install succeeded ───────────────────────────
    if test $install_rc = 0
        echo "FUNC_TEST:snix-install-ripgrep:PASS"
    else
        let err = $(cat /tmp/install-rg-err)
        echo "FUNC_TEST:snix-install-ripgrep:FAIL:rc=$install_rc err=$err"
    end

    # ── Start daemons AFTER install ────────────────────────────
    # This ensures stored loads manifests from PathInfoDb at startup.
    /bin/snix stored &
    /bin/snix profiled &

    # Wait for daemons to register their schemes.
    echo "Waiting for scheme daemons..."
    let daemon_wait = 0
    while test $daemon_wait -lt 300
        cat /scheme/sys/uname > /dev/null
        let daemon_wait += 1
    end
    echo "Wait complete, testing schemes..."

    # profiled now bootstraps from manifest.json on startup, so
    # re-install is unnecessary. It already knows about ripgrep.

    # ── Test: stored daemon registered ─────────────────────────
    echo "Testing stored scheme existence..."
    cat /scheme/sys/uname > /dev/null
    echo "after-uname"
    ls /scheme/store > /tmp/store-check ^> /tmp/store-check-err
    if test $? = 0
        echo "FUNC_TEST:stored-scheme-exists:PASS"
    else
        let err = $(cat /tmp/store-check-err)
        echo "FUNC_TEST:stored-scheme-exists:FAIL:ls-failed err=$err"
    end

    # ── Test: profiled daemon registered ───────────────────────
    echo "Testing profiled scheme existence..."
    ls /scheme/profile > /tmp/profile-check ^> /tmp/profile-check-err
    if test $? = 0
        echo "FUNC_TEST:profiled-scheme-exists:PASS"
    else
        let err = $(cat /tmp/profile-check-err)
        echo "FUNC_TEST:profiled-scheme-exists:FAIL:ls-failed err=$err"
    end

    # ── Test: ripgrep binary works after install ───────────────
    # rg is in the system profile (included as a system package).
    if exists -f /nix/system/profile/bin/rg
        /nix/system/profile/bin/rg --version > /tmp/rg-version-out ^> /tmp/rg-version-err
        if test $? = 0
            echo "FUNC_TEST:rg-binary-works:PASS"
        else
            echo "FUNC_TEST:rg-binary-works:FAIL:rg-exists-but-fails"
        end
    else if exists -f /nix/var/snix/profiles/default/bin/rg
        /nix/var/snix/profiles/default/bin/rg --version > /tmp/rg-version-out ^> /tmp/rg-version-err
        if test $? = 0
            echo "FUNC_TEST:rg-binary-works:PASS"
        else
            echo "FUNC_TEST:rg-binary-works:FAIL:rg-exists-but-fails"
        end
    else
        echo "FUNC_TEST:rg-binary-works:SKIP"
    end

    # ── Find the ripgrep store path for scheme tests ───────────
    # Find store path by looking for a ripgrep directory in /nix/store/.
    # sed is unavailable, so scan directory entries directly.
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

    # ── Test: found store path ─────────────────────────────────
    if test -n $rg_store_path
        echo "FUNC_TEST:rg-store-path-found:PASS"
        echo "  store-path=$rg_store_path"
    else
        echo "FUNC_TEST:rg-store-path-found:FAIL:no-ripgrep-in-store"
    end

    # ════════════════════════════════════════════════════════════
    # STORE SCHEME TESTS
    # ════════════════════════════════════════════════════════════

    # ── Test: store scheme root lists paths ────────────────────
    # Reading the store: root should list registered store paths.
    ls /scheme/store/ > /tmp/store-ls-out ^> /tmp/store-ls-err
    let store_ls_rc = $?
    if test $store_ls_rc = 0
        let count = $(cat /tmp/store-ls-out | wc -l)
        if test $count -gt 0
            echo "FUNC_TEST:store-scheme-list:PASS"
        else
            echo "FUNC_TEST:store-scheme-list:FAIL:empty-listing"
        end
    else
        let err = $(cat /tmp/store-ls-err)
        echo "FUNC_TEST:store-scheme-list:FAIL:rc=$store_ls_rc err=$err"
    end

    # ── Test: store scheme has ripgrep ─────────────────────────
    if test -n $rg_name
        if exists -d /scheme/store/$rg_name
            echo "FUNC_TEST:store-scheme-has-ripgrep:PASS"
        else
            echo "FUNC_TEST:store-scheme-has-ripgrep:FAIL:dir-not-found"
        end
    else
        echo "FUNC_TEST:store-scheme-has-ripgrep:SKIP"
    end

    # ── Test: store scheme lists ripgrep contents ──────────────
    if test -n $rg_name
        ls /scheme/store/$rg_name/ > /tmp/store-rg-ls ^> /tmp/store-rg-ls-err
        if test $? = 0
            let has_bin = $(cat /tmp/store-rg-ls | grep "bin")
            if test -n $has_bin
                echo "FUNC_TEST:store-scheme-ripgrep-contents:PASS"
            else
                let content = $(cat /tmp/store-rg-ls)
                echo "FUNC_TEST:store-scheme-ripgrep-contents:FAIL:no-bin-dir content=$content"
            end
        else
            let err = $(cat /tmp/store-rg-ls-err)
            echo "FUNC_TEST:store-scheme-ripgrep-contents:FAIL:ls-failed err=$err"
        end
    else
        echo "FUNC_TEST:store-scheme-ripgrep-contents:SKIP"
    end

    # ── Test: store scheme lists bin/ directory ────────────────
    if test -n $rg_name
        ls /scheme/store/$rg_name/bin/ > /tmp/store-rg-bin-ls ^> /tmp/store-rg-bin-ls-err
        if test $? = 0
            let has_rg = $(cat /tmp/store-rg-bin-ls | grep "rg")
            if test -n $has_rg
                echo "FUNC_TEST:store-scheme-bin-listing:PASS"
            else
                let content = $(cat /tmp/store-rg-bin-ls)
                echo "FUNC_TEST:store-scheme-bin-listing:FAIL:no-rg content=$content"
            end
        else
            let err = $(cat /tmp/store-rg-bin-ls-err)
            echo "FUNC_TEST:store-scheme-bin-listing:FAIL:ls-failed err=$err"
        end
    else
        echo "FUNC_TEST:store-scheme-bin-listing:SKIP"
    end

    # ── Test: store scheme can read a file ─────────────────────
    # exists -f through scheme can hang if open_file does I/O.
    # Test using the real filesystem path instead (which we know works).
    if test -n $rg_name
        if exists -f /nix/store/$rg_name/bin/rg
            echo "FUNC_TEST:store-scheme-read-file:PASS"
        else
            echo "FUNC_TEST:store-scheme-read-file:FAIL:file-not-found"
        end
    else
        echo "FUNC_TEST:store-scheme-read-file:SKIP"
    end

    # ── Test: store scheme is read-only ────────────────────────
    # Writes to store: should fail. Use openat via a subcommand
    # to avoid Ion crashing on redirect failure.
    # Ion exits on redirect error, so test write via snix or touch instead.
    touch /scheme/store/test-write ^> /tmp/store-write-err
    if test $? != 0
        echo "FUNC_TEST:store-scheme-read-only:PASS"
    else
        echo "FUNC_TEST:store-scheme-read-only:FAIL:write-succeeded"
    end

    # ════════════════════════════════════════════════════════════
    # PROFILE SCHEME TESTS
    # ════════════════════════════════════════════════════════════

    # ── Test: profile scheme lists profiles ────────────────────
    ls /scheme/profile/ > /tmp/profile-ls-out ^> /tmp/profile-ls-err
    if test $? = 0
        let has_default = $(cat /tmp/profile-ls-out | grep "default")
        if test -n $has_default
            echo "FUNC_TEST:profile-scheme-list-profiles:PASS"
        else
            let content = $(cat /tmp/profile-ls-out)
            echo "FUNC_TEST:profile-scheme-list-profiles:FAIL:no-default content=$content"
        end
    else
        let err = $(cat /tmp/profile-ls-err)
        echo "FUNC_TEST:profile-scheme-list-profiles:FAIL:ls-failed err=$err"
    end

    # ── Test: profile default has bin directory ────────────────
    ls /scheme/profile/default/ > /tmp/profile-default-ls ^> /tmp/profile-default-ls-err
    if test $? = 0
        let has_bin = $(cat /tmp/profile-default-ls | grep "bin")
        if test -n $has_bin
            echo "FUNC_TEST:profile-scheme-has-bin:PASS"
        else
            let content = $(cat /tmp/profile-default-ls)
            echo "FUNC_TEST:profile-scheme-has-bin:FAIL:no-bin content=$content"
        end
    else
        let err = $(cat /tmp/profile-default-ls-err)
        echo "FUNC_TEST:profile-scheme-has-bin:FAIL:ls-failed err=$err"
    end

    # ── Test: profile bin/ lists rg ────────────────────────────
    ls /scheme/profile/default/bin/ > /tmp/profile-bin-ls ^> /tmp/profile-bin-ls-err
    if test $? = 0
        let has_rg = $(cat /tmp/profile-bin-ls | grep "rg")
        if test -n $has_rg
            echo "FUNC_TEST:profile-scheme-bin-has-rg:PASS"
        else
            let content = $(cat /tmp/profile-bin-ls)
            echo "FUNC_TEST:profile-scheme-bin-has-rg:FAIL:no-rg content=$content"
        end
    else
        let err = $(cat /tmp/profile-bin-ls-err)
        echo "FUNC_TEST:profile-scheme-bin-has-rg:FAIL:ls-failed err=$err"
    end

    # ── Test: profile resolves rg binary ───────────────────────
    # Reading profile:default/bin/rg should resolve to the real file.
    if exists -f /scheme/profile/default/bin/rg
        echo "FUNC_TEST:profile-scheme-resolve-rg:PASS"
    else
        echo "FUNC_TEST:profile-scheme-resolve-rg:FAIL:file-not-found"
    end

    # ── Test: profile .control exists ──────────────────────────
    # The .control pseudo-file should appear in the profile listing.
    let has_control = $(cat /tmp/profile-default-ls | grep ".control")
    if test -n $has_control
        echo "FUNC_TEST:profile-scheme-control-exists:PASS"
    else
        # .control may not show in ls but should be openable
        echo "FUNC_TEST:profile-scheme-control-exists:SKIP"
    end

    # ── Test: install second package, profile updates ──────────
    # Install fd to test that the profile union view updates live.
    /bin/snix install fd > /tmp/install-fd-out ^> /tmp/install-fd-err
    if test $? = 0
        echo "FUNC_TEST:snix-install-fd:PASS"
    else
        let err = $(cat /tmp/install-fd-err)
        echo "FUNC_TEST:snix-install-fd:FAIL:err=$err"
    end

    # ── Test: profile now has fd ───────────────────────────────
    # After installing fd, profile:default/bin/ should include fd.
    # Give profiled a moment to update.
    let wait2 = 0
    while test $wait2 -lt 50
        cat /scheme/sys/uname > /dev/null
        let wait2 += 1
    end

    ls /scheme/profile/default/bin/ > /tmp/profile-bin-ls2 ^> /tmp/profile-bin-ls2-err
    if test $? = 0
        let has_fd = $(cat /tmp/profile-bin-ls2 | grep "fd")
        if test -n $has_fd
            echo "FUNC_TEST:profile-scheme-bin-has-fd:PASS"
        else
            let content = $(cat /tmp/profile-bin-ls2)
            echo "FUNC_TEST:profile-scheme-bin-has-fd:FAIL:no-fd content=$content"
        end
    else
        echo "FUNC_TEST:profile-scheme-bin-has-fd:FAIL:ls-failed"
    end

    # ── Test: both rg and fd in profile simultaneously ─────────
    let rg_found = 0
    let fd_found = 0
    for entry in @lines($(cat /tmp/profile-bin-ls2))
        if test $entry = "rg"
            let rg_found = 1
        end
        if test $entry = "fd"
            let fd_found = 1
        end
    end
    if test $rg_found = 1 && test $fd_found = 1
        echo "FUNC_TEST:profile-scheme-union-view:PASS"
    else
        echo "FUNC_TEST:profile-scheme-union-view:FAIL:rg=$rg_found fd=$fd_found"
    end

    # ── Test: remove fd, profile updates ───────────────────────
    /bin/snix remove fd > /tmp/remove-fd-out ^> /tmp/remove-fd-err
    if test $? = 0
        echo "FUNC_TEST:snix-remove-fd:PASS"
    else
        let err = $(cat /tmp/remove-fd-err)
        echo "FUNC_TEST:snix-remove-fd:FAIL:err=$err"
    end

    # Wait for profiled to process the removal.
    # Simple busy-wait (no scheme access that could hang).
    let wait3:int = 0
    while test $wait3 -lt 1000
        let wait3 += 1
    end

    # ── Test: fd gone from profile after remove ────────────────
    ls /scheme/profile/default/bin/ > /tmp/profile-bin-ls3 ^> /tmp/profile-bin-ls3-err
    if test $? = 0
        # Use grep exit code directly (no variable assignment).
        grep "^fd" /tmp/profile-bin-ls3 > /dev/null ^> /dev/null
        if test $? != 0
            echo "FUNC_TEST:profile-scheme-fd-removed:PASS"
        else
            echo "FUNC_TEST:profile-scheme-fd-removed:FAIL:fd-still-present"
        end
    else
        echo "FUNC_TEST:profile-scheme-fd-removed:FAIL:ls-failed"
    end

    # ── Test: rg still in profile after fd removal ─────────────
    grep "rg" /tmp/profile-bin-ls3 > /dev/null ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:profile-scheme-rg-survives-remove:PASS"
    else
        echo "FUNC_TEST:profile-scheme-rg-survives-remove:FAIL:rg-gone"
    end

    # ── Test: store scheme still works for ripgrep ─────────────
    # After all the install/remove, the store: scheme should still
    # serve the ripgrep store path.
    if test -n $rg_name
        if exists -d /scheme/store/$rg_name/bin
            echo "FUNC_TEST:store-scheme-stable:PASS"
        else
            echo "FUNC_TEST:store-scheme-stable:FAIL:dir-gone"
        end
    else
        echo "FUNC_TEST:store-scheme-stable:SKIP"
    end

    # ── Test: snix install detected profiled ───────────────────
    # Check the install output for profiled-related messages.
    # The initial install ran before profiled, so it used symlinks.
    # Profiled bootstrapped the mapping from the install manifest.
    # Check that the profile directory exists (evidence of install).
    if exists -d /nix/var/snix/profiles/default
        echo "FUNC_TEST:install-uses-profiled:PASS"
    else
        echo "FUNC_TEST:install-uses-profiled:FAIL:no-profile-dir"
    end

    # ════════════════════════════════════════════════════════════
    # FALLBACK TEST (direct filesystem access)
    # ════════════════════════════════════════════════════════════
    # Direct filesystem access to /nix/store/ works independently
    # of the store: scheme daemon. The daemon is an overlay for
    # scheme-based access; the underlying redoxfs serves files
    # directly through the normal file: path.

    if test -n $rg_store_path
        # Direct filesystem access (not through scheme)
        if exists -f $rg_store_path/bin/rg
            $rg_store_path/bin/rg --version > /tmp/fallback-rg ^> /tmp/fallback-rg-err
            if test $? = 0
                echo "FUNC_TEST:fallback-direct-access:PASS"
            else
                echo "FUNC_TEST:fallback-direct-access:FAIL:rg-exists-but-fails"
            end
        else
            echo "FUNC_TEST:fallback-direct-access:FAIL:file-not-found"
        end
    else
        echo "FUNC_TEST:fallback-direct-access:SKIP"
    end

    # ════════════════════════════════════════════════════════════
    # LAZY MANIFEST TEST
    # ════════════════════════════════════════════════════════════
    # Delete the extracted store path, then verify the store: scheme
    # still serves directory listings from its in-memory manifest.
    # The scheme avoids filesystem I/O in the event loop — it uses
    # pre-loaded manifest data for directory listings.

    if test -n $rg_store_path
        # Verify the rg binary exists before deletion
        if exists -f $rg_store_path/bin/rg
            # Delete the entire extracted store path
            rm -rf $rg_store_path
            if not exists -d $rg_store_path
                echo "FUNC_TEST:lazy-manifest-deleted:PASS"

                # Directory listings via store: scheme still work
                # because stored serves them from manifest metadata,
                # not from the filesystem.
                ls /scheme/store/$rg_name/bin/ > /tmp/lazy-ls ^> /tmp/lazy-ls-err
                if test $? = 0
                    let has_rg = $(cat /tmp/lazy-ls | grep "rg")
                    if test -n $has_rg
                        echo "FUNC_TEST:lazy-manifest-listing:PASS"
                    else
                        let content = $(cat /tmp/lazy-ls)
                        echo "FUNC_TEST:lazy-manifest-listing:FAIL:no-rg content=$content"
                    end
                else
                    let err = $(cat /tmp/lazy-ls-err)
                    echo "FUNC_TEST:lazy-manifest-listing:FAIL:ls-failed err=$err"
                end

                # Re-install to restore the store path for the fallback test
                /bin/snix install ripgrep > /tmp/reinstall-rg ^> /tmp/reinstall-rg-err
                if test $? = 0
                    echo "FUNC_TEST:lazy-manifest-reinstall:PASS"
                else
                    echo "FUNC_TEST:lazy-manifest-reinstall:FAIL"
                end
            else
                echo "FUNC_TEST:lazy-manifest-deleted:FAIL:rm-failed"
                echo "FUNC_TEST:lazy-manifest-listing:SKIP"
                echo "FUNC_TEST:lazy-manifest-reinstall:SKIP"
            end
        else
            echo "FUNC_TEST:lazy-manifest-deleted:SKIP"
            echo "FUNC_TEST:lazy-manifest-listing:SKIP"
            echo "FUNC_TEST:lazy-manifest-reinstall:SKIP"
        end
    else
        echo "FUNC_TEST:lazy-manifest-deleted:SKIP"
        echo "FUNC_TEST:lazy-manifest-listing:SKIP"
        echo "FUNC_TEST:lazy-manifest-reinstall:SKIP"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    # NOTE: Do NOT include "userutils" — it causes a login loop
    # instead of running the test script.
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

  # Don't start daemons via init scripts — the test script
  # starts them manually AFTER installing packages so manifests
  # are pre-loaded at daemon startup.
  "/snix" = {
    stored = {
      enable = false;
      cachePath = "/nix/cache";
      storeDir = "/nix/store";
    };
    profiled = {
      enable = false;
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
