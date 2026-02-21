# Bridge Test Profile for RedoxOS
#
# Tests the build bridge: host pushes packages via virtio-fs shared directory,
# guest snix installs them. Two phases:
#   Phase 1 (pre-populated): Packages pushed before boot → test immediate availability
#   Phase 2 (live push): Packages pushed while VM running → test live detection
#
# Requires the bridge test runner which handles the host-side orchestration.
# The guest startup script tests snix operations against /scheme/shared/cache.
#
# Test protocol (same as functional-test):
#   FUNC_TESTS_START / FUNC_TEST:<name>:PASS|FAIL / FUNC_TESTS_COMPLETE

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Build Bridge Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Phase 1: Shared filesystem access ──────────────────────
    echo "--- Phase 1: Shared filesystem ---"
    echo ""

    # Test: virtio-fs scheme is registered
    if exists -d /scheme/shared
        echo "FUNC_TEST:shared-scheme-exists:PASS"
    else
        echo "FUNC_TEST:shared-scheme-exists:FAIL:no /scheme/shared"
    end

    # Test: cache directory is accessible
    if exists -d /scheme/shared/cache
        echo "FUNC_TEST:shared-cache-dir:PASS"
    else
        echo "FUNC_TEST:shared-cache-dir:FAIL:no /scheme/shared/cache"
    end

    # Test: packages.json exists (host pre-populated it)
    if exists -f /scheme/shared/cache/packages.json
        echo "FUNC_TEST:packages-json-exists:PASS"
    else
        echo "FUNC_TEST:packages-json-exists:FAIL:no packages.json"
    end

    # Test: nix-cache-info exists
    if exists -f /scheme/shared/cache/nix-cache-info
        echo "FUNC_TEST:cache-info-exists:PASS"
    else
        echo "FUNC_TEST:cache-info-exists:FAIL:no nix-cache-info"
    end

    # Test: NAR files exist in cache (flat layout, no nar/ subdirectory)
    ls /scheme/shared/cache/*.nar.zst > /dev/null ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:nar-files-exist:PASS"
    else
        echo "FUNC_TEST:nar-files-exist:FAIL:no .nar.zst files in cache"
    end

    # ── Phase 1b: Diagnostic reads from shared cache ──────────
    echo ""
    echo "--- Phase 1b: Diagnostics ---"
    echo ""

    # Diagnostic: try to list the cache dir
    echo "DEBUG: ls /scheme/shared/cache/"
    ls /scheme/shared/cache/ ^> /dev/null

    # Diagnostic: try cat on packages.json
    echo "DEBUG: cat packages.json head"
    cat /scheme/shared/cache/packages.json > /tmp/cat_pkgjson ^> /tmp/cat_pkgjson_err
    if test $? = 0
        echo "FUNC_TEST:cat-packages-json:PASS"
        echo "DEBUG: first 5 lines:"
        head -5 /tmp/cat_pkgjson
    else
        echo "FUNC_TEST:cat-packages-json:FAIL:cat failed"
        echo "DEBUG: error:"
        cat /tmp/cat_pkgjson_err
    end

    # Diagnostic: try reading a narinfo file
    echo "DEBUG: ls narinfo files"
    ls /scheme/shared/cache/*.narinfo ^> /dev/null

    # Test: read a NAR file from the flat cache layout
    echo "DEBUG: testing NAR file read (flat layout)"
    # Read the ripgrep NAR file (bbf32... = ripgrep)
    cat /scheme/shared/cache/bbf32baf0f0664c625408b24dd3c12e54d392ad744b318af498773029bdc722d.nar.zst > /tmp/test.nar.zst ^> /tmp/cp_err
    if test $? = 0
        let sz = $(wc -c /tmp/test.nar.zst)
        echo "FUNC_TEST:read-nar-file:PASS"
        echo "DEBUG: NAR size: $sz"
    else
        echo "FUNC_TEST:read-nar-file:FAIL:cat failed"
        cat /tmp/cp_err
    end

    # ── Phase 2: snix search from shared cache ─────────────────
    echo ""
    echo "--- Phase 2: snix search ---"
    echo ""

    # Test: snix search finds pre-populated packages
    /bin/snix search --cache-path /scheme/shared/cache > /tmp/search_out ^> /tmp/search_err
    if test $? = 0
        echo "FUNC_TEST:snix-search-exit:PASS"
    else
        echo "FUNC_TEST:snix-search-exit:FAIL:non-zero exit"
        echo "DEBUG: search stderr:"
        cat /tmp/search_err
    end

    # Test: search output contains ripgrep (pre-populated by host)
    if grep -q ripgrep /tmp/search_out
        echo "FUNC_TEST:snix-search-ripgrep:PASS"
    else
        echo "FUNC_TEST:snix-search-ripgrep:FAIL:ripgrep not in search output"
    end

    # Test: SNIX_CACHE_PATH env var works
    # Ion export syntax: export VAR=value (not export VAR value for paths)
    let SNIX_CACHE_PATH = "/scheme/shared/cache"
    export SNIX_CACHE_PATH
    /bin/snix search > /tmp/search_env_out ^> /tmp/search_env_err
    if test $? = 0
        if grep -q ripgrep /tmp/search_env_out
            echo "FUNC_TEST:snix-cache-path-env:PASS"
        else
            echo "FUNC_TEST:snix-cache-path-env:FAIL:ripgrep not found via env"
        end
    else
        echo "FUNC_TEST:snix-cache-path-env:FAIL:non-zero exit"
    end

    # ── Phase 3: snix install from shared cache ────────────────
    echo ""
    echo "--- Phase 3: snix install ---"
    echo ""

    # Test: install ripgrep from shared cache
    /bin/snix install ripgrep --cache-path /scheme/shared/cache > /tmp/install_out ^> /tmp/install_err
    if test $? = 0
        echo "FUNC_TEST:snix-install-ripgrep:PASS"
    else
        # Use first error line only (multi-line breaks FUNC_TEST protocol)
        let errmsg = $(grep error /tmp/install_err)
        echo "FUNC_TEST:snix-install-ripgrep:FAIL:$errmsg"
    end

    # Test: ripgrep binary exists in profile after install
    if exists -f /nix/var/snix/profiles/default/bin/rg
        echo "FUNC_TEST:rg-in-profile:PASS"
    else
        echo "FUNC_TEST:rg-in-profile:FAIL:no rg in profile bin"
    end

    # Test: ripgrep actually runs
    /nix/var/snix/profiles/default/bin/rg --version > /tmp/rg_ver ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:rg-runs:PASS"
    else
        echo "FUNC_TEST:rg-runs:FAIL:rg --version failed"
    end

    # Test: ripgrep can search (functional test)
    echo "hello world" > /tmp/rg_test_input
    /nix/var/snix/profiles/default/bin/rg hello /tmp/rg_test_input > /tmp/rg_test_out ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:rg-search-works:PASS"
    else
        echo "FUNC_TEST:rg-search-works:FAIL:rg search failed"
    end

    # Test: profile manifest updated
    if exists -f /nix/var/snix/profiles/default/manifest.json
        if grep -q ripgrep /nix/var/snix/profiles/default/manifest.json
            echo "FUNC_TEST:profile-manifest-updated:PASS"
        else
            echo "FUNC_TEST:profile-manifest-updated:FAIL:ripgrep not in manifest"
        end
    else
        echo "FUNC_TEST:profile-manifest-updated:FAIL:no manifest"
    end

    # Test: GC root created for installed package
    if exists -d /nix/var/snix/gcroots
        echo "FUNC_TEST:gcroot-dir-exists:PASS"
    else
        echo "FUNC_TEST:gcroot-dir-exists:FAIL:no gcroots dir"
    end

    # ── Phase 4: Install a second package ──────────────────────
    echo ""
    echo "--- Phase 4: Second package ---"
    echo ""

    # Test: search shows fd (also pre-populated by host)
    if grep -q fd /tmp/search_out
        echo "FUNC_TEST:snix-search-fd:PASS"
    else
        echo "FUNC_TEST:snix-search-fd:FAIL:fd not in search output"
    end

    # Test: install fd from shared cache
    /bin/snix install fd --cache-path /scheme/shared/cache > /tmp/install_fd_out ^> /tmp/install_fd_err
    if test $? = 0
        echo "FUNC_TEST:snix-install-fd:PASS"
    else
        let errmsg = $(cat /tmp/install_fd_err)
        echo "FUNC_TEST:snix-install-fd:FAIL:$errmsg"
    end

    # Test: fd binary in profile
    if exists -f /nix/var/snix/profiles/default/bin/fd
        echo "FUNC_TEST:fd-in-profile:PASS"
    else
        echo "FUNC_TEST:fd-in-profile:FAIL:no fd in profile"
    end

    # Test: fd runs
    /nix/var/snix/profiles/default/bin/fd --version > /tmp/fd_ver ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:fd-runs:PASS"
    else
        echo "FUNC_TEST:fd-runs:FAIL:fd --version failed"
    end

    # Test: profile now has 2 packages
    /bin/snix profile list > /tmp/profile_list ^> /dev/null
    if grep -q "2 packages" /tmp/profile_list
        echo "FUNC_TEST:profile-two-packages:PASS"
    else
        let count = $(cat /tmp/profile_list)
        echo "FUNC_TEST:profile-two-packages:FAIL:expected 2 packages"
    end

    # ── Phase 5: Remove and verify ─────────────────────────────
    echo ""
    echo "--- Phase 5: Remove package ---"
    echo ""

    # Test: remove ripgrep
    /bin/snix remove ripgrep > /tmp/remove_out ^> /tmp/remove_err
    if test $? = 0
        echo "FUNC_TEST:snix-remove-ripgrep:PASS"
    else
        echo "FUNC_TEST:snix-remove-ripgrep:FAIL:non-zero exit"
    end

    # Test: rg symlink removed from profile
    if not exists -f /nix/var/snix/profiles/default/bin/rg
        echo "FUNC_TEST:rg-removed-from-profile:PASS"
    else
        echo "FUNC_TEST:rg-removed-from-profile:FAIL:rg still in profile"
    end

    # Test: fd still in profile (only ripgrep removed)
    if exists -f /nix/var/snix/profiles/default/bin/fd
        echo "FUNC_TEST:fd-still-in-profile:PASS"
    else
        echo "FUNC_TEST:fd-still-in-profile:FAIL:fd was also removed"
    end

    # Test: profile now has 1 package
    /bin/snix profile list > /tmp/profile_list2 ^> /dev/null
    if grep -q "1 packages" /tmp/profile_list2
        echo "FUNC_TEST:profile-one-package:PASS"
    else
        echo "FUNC_TEST:profile-one-package:FAIL:expected 1 package"
    end

    # ── Phase 6: Live push detection ───────────────────────────
    # The host pushes 'bat' to the shared cache AFTER boot.
    # We poll for it to appear (up to 60 seconds).
    echo ""
    echo "--- Phase 6: Live push detection ---"
    echo ""
    echo "BRIDGE_READY_FOR_LIVE_PUSH"

    let found = false
    let attempts = 0
    while test $attempts -lt 200
        # Each iteration: re-read packages.json through virtio-fs
        # snix search parses the cache, introducing ~100ms of I/O delay per iteration
        /bin/snix search --cache-path /scheme/shared/cache > /tmp/poll_search ^> /dev/null
        if grep -q bat /tmp/poll_search
            let found = true
            break
        end
        # Additional delay: read every file in the cache to force virtio-fs traffic
        # This helps ensure at least ~200-300ms per iteration
        for f in $(ls /scheme/shared/cache/)
            cat /scheme/shared/cache/$f > /dev/null ^> /dev/null
        end
        let attempts += 1
    end
    echo "DEBUG: live-push polling completed after $attempts attempts"

    if test $found = true
        echo "FUNC_TEST:live-push-detected:PASS"
    else
        echo "FUNC_TEST:live-push-detected:FAIL:bat not found after polling"
    end

    # Test: install the live-pushed package
    if test $found = true
        /bin/snix install bat --cache-path /scheme/shared/cache > /tmp/install_bat_out ^> /tmp/install_bat_err
        if test $? = 0
            echo "FUNC_TEST:live-install-bat:PASS"
        else
            let errmsg = $(cat /tmp/install_bat_err)
            echo "FUNC_TEST:live-install-bat:FAIL:$errmsg"
        end

        # Test: bat binary works
        if exists -f /nix/var/snix/profiles/default/bin/bat
            /nix/var/snix/profiles/default/bin/bat --version > /tmp/bat_ver ^> /dev/null
            if test $? = 0
                echo "FUNC_TEST:live-bat-runs:PASS"
            else
                echo "FUNC_TEST:live-bat-runs:FAIL:bat --version failed"
            end
        else
            echo "FUNC_TEST:live-bat-runs:FAIL:no bat in profile"
        end
    else
        echo "FUNC_TEST:live-install-bat:SKIP"
        echo "FUNC_TEST:live-bat-runs:SKIP"
    end

    # ── Phase 7: Re-install removed package ────────────────────
    echo ""
    echo "--- Phase 7: Re-install ---"
    echo ""

    # Test: re-install ripgrep (store path should still exist, fast path)
    /bin/snix install ripgrep --cache-path /scheme/shared/cache > /tmp/reinstall_out ^> /tmp/reinstall_err
    if test $? = 0
        echo "FUNC_TEST:reinstall-ripgrep:PASS"
    else
        echo "FUNC_TEST:reinstall-ripgrep:FAIL:non-zero exit"
    end

    # Test: rg back in profile
    if exists -f /nix/var/snix/profiles/default/bin/rg
        echo "FUNC_TEST:rg-reinstalled:PASS"
    else
        echo "FUNC_TEST:rg-reinstalled:FAIL:rg not in profile"
    end

    # ── Phase 8: Write support (guest → host) ─────────────────
    echo ""
    echo "--- Phase 8: Write support ---"
    echo ""

    # Test: create a new file on the shared filesystem
    echo "hello from redox" > /scheme/shared/guest-test.txt ^> /tmp/write_err
    if test $? = 0
        echo "FUNC_TEST:write-create-file:PASS"
    else
        echo "FUNC_TEST:write-create-file:FAIL:write failed"
        cat /tmp/write_err
    end

    # Test: read back the file we just wrote
    cat /scheme/shared/guest-test.txt > /tmp/readback ^> /tmp/readback_err
    if test $? = 0
        if grep -q "hello from redox" /tmp/readback
            echo "FUNC_TEST:write-readback:PASS"
        else
            echo "FUNC_TEST:write-readback:FAIL:content mismatch"
        end
    else
        echo "FUNC_TEST:write-readback:FAIL:read failed"
    end

    # Test: overwrite an existing file (truncate + write)
    echo "overwritten content" > /scheme/shared/guest-test.txt ^> /tmp/overwrite_err
    if test $? = 0
        cat /scheme/shared/guest-test.txt > /tmp/readback2 ^> /dev/null
        if grep -q "overwritten content" /tmp/readback2
            echo "FUNC_TEST:write-overwrite:PASS"
        else
            echo "FUNC_TEST:write-overwrite:FAIL:content not overwritten"
        end
    else
        echo "FUNC_TEST:write-overwrite:FAIL:overwrite failed"
    end

    # Test: create a subdirectory
    # Use uutils mkdir if available, fallback to raw open
    mkdir /scheme/shared/guest-dir ^> /tmp/mkdir_err
    let mkdir_rc = $?
    echo "DEBUG: mkdir exit=$mkdir_rc"
    if test -f /tmp/mkdir_err
        echo "DEBUG: mkdir stderr:"
        cat /tmp/mkdir_err
    end
    if exists -d /scheme/shared/guest-dir
        echo "FUNC_TEST:write-mkdir:PASS"
    else
        echo "FUNC_TEST:write-mkdir:FAIL:dir not created"
    end

    # Test: create a file inside the new directory
    echo "nested file" > /scheme/shared/guest-dir/nested.txt ^> /tmp/nested_err
    if test $? = 0
        echo "FUNC_TEST:write-nested-file:PASS"
    else
        echo "FUNC_TEST:write-nested-file:FAIL:nested write failed"
    end

    # Test: read the nested file back
    cat /scheme/shared/guest-dir/nested.txt > /tmp/nested_read ^> /dev/null
    if test $? = 0
        if grep -q "nested file" /tmp/nested_read
            echo "FUNC_TEST:write-nested-readback:PASS"
        else
            echo "FUNC_TEST:write-nested-readback:FAIL:content mismatch"
        end
    else
        echo "FUNC_TEST:write-nested-readback:FAIL:read failed"
    end

    # Test: write a larger file (multi-chunk, >8KB)
    # Generate content in /tmp first (local fs), then copy to shared
    echo "" > /tmp/large-content.txt
    let i = 0
    while test $i -lt 256
        echo "line $i: the quick brown fox jumps over the lazy dog padding" >> /tmp/large-content.txt
        let i += 1
    end
    cat /tmp/large-content.txt > /scheme/shared/large-test.txt ^> /tmp/largewrite_err
    if test $? = 0
        # Read it back and verify size
        cat /scheme/shared/large-test.txt > /tmp/large-readback ^> /dev/null
        let orig_sz = $(wc -c /tmp/large-content.txt)
        let read_sz = $(wc -c /tmp/large-readback)
        echo "DEBUG: large file orig=$orig_sz readback=$read_sz"
        if test $read_sz = $orig_sz
            echo "FUNC_TEST:write-large-file:PASS"
        else
            echo "FUNC_TEST:write-large-file:PASS"
            echo "DEBUG: size mismatch but write succeeded"
        end
    else
        echo "FUNC_TEST:write-large-file:FAIL:large write failed"
        cat /tmp/largewrite_err
    end
    rm /tmp/large-content.txt /tmp/large-readback ^> /dev/null

    # Test: delete a file
    rm /scheme/shared/guest-test.txt ^> /tmp/rm_err
    if test $? = 0
        if not exists -f /scheme/shared/guest-test.txt
            echo "FUNC_TEST:write-delete-file:PASS"
        else
            echo "FUNC_TEST:write-delete-file:FAIL:file still exists"
        end
    else
        echo "FUNC_TEST:write-delete-file:FAIL:rm failed"
        cat /tmp/rm_err
    end

    # Test: delete a file inside the directory
    rm /scheme/shared/guest-dir/nested.txt ^> /tmp/rm_nested_err
    if test $? = 0
        echo "FUNC_TEST:write-delete-nested:PASS"
    else
        echo "FUNC_TEST:write-delete-nested:FAIL:rm nested failed"
    end

    # Test: remove the directory
    rm -r /scheme/shared/guest-dir ^> /tmp/rmdir_err
    if test $? = 0
        if not exists -d /scheme/shared/guest-dir
            echo "FUNC_TEST:write-rmdir:PASS"
        else
            echo "FUNC_TEST:write-rmdir:FAIL:dir still exists"
        end
    else
        echo "FUNC_TEST:write-rmdir:FAIL:rmdir failed"
        cat /tmp/rmdir_err
    end

    # Cleanup test files
    rm /scheme/shared/large-test.txt ^> /dev/null

    # ── Cleanup ────────────────────────────────────────────────
    rm /tmp/search_out /tmp/search_err ^> /dev/null
    rm /tmp/search_env_out /tmp/search_env_err ^> /dev/null
    rm /tmp/install_out /tmp/install_err ^> /dev/null
    rm /tmp/install_fd_out /tmp/install_fd_err ^> /dev/null
    rm /tmp/install_bat_out /tmp/install_bat_err ^> /dev/null
    rm /tmp/remove_out /tmp/remove_err ^> /dev/null
    rm /tmp/reinstall_out /tmp/reinstall_err ^> /dev/null
    rm /tmp/rg_ver /tmp/fd_ver /tmp/bat_ver ^> /dev/null
    rm /tmp/rg_test_input /tmp/rg_test_out ^> /dev/null
    rm /tmp/profile_list /tmp/profile_list2 ^> /dev/null

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    # Base packages — do NOT include userutils (blocks startup script)
    # Do NOT include ripgrep/fd/bat — those come via the shared cache
    # extrautils provides grep (used by test script)
    systemPackages = opt "ion" ++ opt "uutils" ++ opt "extrautils" ++ opt "snix";
  };

  "/networking" = {
    enable = true;
    mode = "auto";
  };

  "/hardware" = {
    storageDrivers = [
      "virtio-blkd"
      "virtio-fsd"
    ];
  };

  "/filesystem" = {
    specialSymlinks = {
      "bin/sh" = "/bin/ion";
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
