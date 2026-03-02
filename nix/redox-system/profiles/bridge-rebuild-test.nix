# Bridge Rebuild Integration Test
#
# Tests the REAL build bridge: guest sends a RebuildConfig via virtio-fs,
# host's build-bridge daemon builds a new rootTree via bridge-eval.nix,
# exports packages to the shared cache, guest installs and activates.
#
# Unlike bridge-test.nix (which uses a mock daemon), this profile requires
# the real build-bridge daemon running on the host alongside the VM.

{ pkgs, lib, ... }:

let
  # Helper to include a package only if it exists
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
    echo ""
    echo "=== Bridge Rebuild Integration Test ==="
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Phase 1: Pre-flight checks ────────────────────────────
    echo "--- Phase 1: Pre-flight checks ---"

    # Verify snix is available
    if exists -f /bin/snix
        echo "FUNC_TEST:snix-available:PASS"
    else
        echo "FUNC_TEST:snix-available:FAIL:snix not in /bin"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Verify shared filesystem is mounted
    if exists -d /scheme/shared
        echo "FUNC_TEST:shared-fs-mounted:PASS"
    else
        echo "FUNC_TEST:shared-fs-mounted:FAIL:/scheme/shared not available"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Record current hostname before rebuild
    let current_hostname = $(cat /etc/hostname)
    echo "DEBUG: current hostname = $current_hostname"

    # Record current manifest package count
    let current_manifest = $(cat /etc/redox-system/manifest.json)
    echo "DEBUG: have manifest"

    echo ""
    echo "--- Phase 2: Write bridge rebuild config ---"

    # Create the requests/responses directories via shared fs
    mkdir /scheme/shared/requests ^> /dev/null
    mkdir /scheme/shared/responses ^> /dev/null

    # Write a configuration that changes hostname
    # The host daemon should build a new rootTree with this change
    # while PRESERVING all existing packages from the profile
    echo '{"hostname":"rebuilt-via-bridge"}' > /scheme/shared/bridge-rebuild-config.json ^> /tmp/cfg_err
    if test $? = 0
        echo "FUNC_TEST:write-config:PASS"
    else
        echo "FUNC_TEST:write-config:FAIL:could not write config to shared fs"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Verify the config is readable back
    if exists -f /scheme/shared/bridge-rebuild-config.json
        echo "FUNC_TEST:config-readable:PASS"
    else
        echo "FUNC_TEST:config-readable:FAIL:config not readable via shared fs"
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    echo ""
    echo "--- Phase 3: Signal host and run bridge rebuild ---"

    # Signal the host that we're ready for the bridge rebuild
    # The host test runner starts the build-bridge daemon when it sees this
    echo "BRIDGE_REBUILD_READY"

    # Give the host daemon a moment to start watching
    # (use file reads as delay since there's no sleep binary)
    let i = 0
    while test $i -lt 100
        cat /dev/null ^> /dev/null
        let i += 1
    end

    # Quick diagnostic: verify shared filesystem is still responsive
    echo "DEBUG: checking shared fs before rebuild..."
    ls /scheme/shared/
    echo "DEBUG: checking responses dir..."
    ls /scheme/shared/responses/
    echo "DEBUG: checking requests dir..."
    ls /scheme/shared/requests/
    echo "DEBUG: starting snix system rebuild --bridge"

    # Run the real bridge rebuild
    # This will:
    #   1. Evaluate the config JSON
    #   2. Write a request to /scheme/shared/requests/
    #   3. Poll /scheme/shared/responses/ for the daemon's answer
    #   4. Install packages from /scheme/shared/cache/
    #   5. Activate the new system (switch manifest + update profile)
    #
    # DO NOT redirect stderr — let snix's progress output go to serial
    # so we can see what's happening in the test runner's log.
    /bin/snix system rebuild --bridge \
        --config /scheme/shared/bridge-rebuild-config.json \
        --shared-dir /scheme/shared \
        --timeout 120 \
        --manifest /etc/redox-system/manifest.json \
        --gen-dir /tmp/bridge-rebuild-gens \
        > /tmp/rebuild_stdout
    let rebuild_rc = $?

    echo "DEBUG: rebuild exit code = $rebuild_rc"

    # Show stdout
    if exists -f /tmp/rebuild_stdout
        echo "DEBUG: stdout:"
        cat /tmp/rebuild_stdout
    end

    echo ""
    echo "--- Phase 4: Verify rebuild results ---"

    # Test: rebuild completed successfully
    if test $rebuild_rc = 0
        echo "FUNC_TEST:rebuild-success:PASS"
    else
        echo "FUNC_TEST:rebuild-success:FAIL:exit=$rebuild_rc"
        # Show what happened
        if exists -f /tmp/rebuild_stderr
            head -5 /tmp/rebuild_stderr
        end
        echo "FUNC_TESTS_COMPLETE"
        exit
    end

    # Test: hostname was updated in manifest
    if grep -q "rebuilt-via-bridge" /etc/redox-system/manifest.json
        echo "FUNC_TEST:hostname-updated:PASS"
    else
        echo "FUNC_TEST:hostname-updated:FAIL:hostname not changed in manifest"
    end

    # Test: essential packages are preserved (ion must still be in manifest)
    if grep -q "ion" /etc/redox-system/manifest.json
        echo "FUNC_TEST:ion-preserved:PASS"
    else
        echo "FUNC_TEST:ion-preserved:FAIL:ion missing from manifest"
    end

    # Test: snix is preserved
    if grep -q "snix" /etc/redox-system/manifest.json
        echo "FUNC_TEST:snix-preserved:PASS"
    else
        echo "FUNC_TEST:snix-preserved:FAIL:snix missing from manifest"
    end

    # Test: uutils is preserved
    if grep -q "uutils" /etc/redox-system/manifest.json
        echo "FUNC_TEST:uutils-preserved:PASS"
    else
        echo "FUNC_TEST:uutils-preserved:FAIL:uutils missing from manifest"
    end

    # Test: a generation was created
    if exists -d /tmp/bridge-rebuild-gens
        let gen_count = $(ls /tmp/bridge-rebuild-gens/ | wc -l)
        if test $gen_count -gt 0
            echo "FUNC_TEST:generation-created:PASS"
        else
            echo "FUNC_TEST:generation-created:FAIL:no generations in dir"
        end
    else
        echo "FUNC_TEST:generation-created:FAIL:gen dir not created"
    end

    # Test: rebuild with --dry-run shows changes without modifying
    /bin/snix system rebuild --bridge \
        --config /scheme/shared/bridge-rebuild-config.json \
        --shared-dir /scheme/shared \
        --dry-run \
        > /tmp/dryrun_out ^> /tmp/dryrun_err
    let dryrun_rc = $?
    if test $dryrun_rc = 0
        if grep -q "Dry run" /tmp/dryrun_out
            echo "FUNC_TEST:dryrun-works:PASS"
        else
            echo "FUNC_TEST:dryrun-works:FAIL:no dry run output"
        end
    else
        echo "FUNC_TEST:dryrun-works:FAIL:exit=$dryrun_rc"
    end

    # Cleanup
    rm /tmp/rebuild_stdout /tmp/rebuild_stderr ^> /dev/null
    rm /tmp/dryrun_out /tmp/dryrun_err ^> /dev/null
    rm -r /tmp/bridge-rebuild-gens ^> /dev/null

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    # Packages for the test VM
    # MUST NOT include userutils — when present, init runs getty instead of /startup.sh
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

  # Bridge rebuild installs ~277MB of packages to /nix/store/
  # on top of the existing ~200MB rootTree. Default 768MB is too small.
  "/boot" = {
    diskSizeMB = 1536;
  };

  "/virtualisation" = {
    vmm = "cloud-hypervisor";
    memorySize = 1024;
    cpus = 2;
  };
}
