# Focused rebuild flow test for RedoxOS
#
# Proves successful rebuild updates live config and publishes generation artifacts:
#   - modifying /etc/redox-system/configuration.nix changes /etc/hostname
#   - package rebuild auto-routes locally without bridge and installs from cache
#   - boot-path change warns that reboot is recommended
#   - snix system generations shows the new generation
#   - /etc/redox-system/generations/N/{manifest.json,metadata.json}
#   - /nix/system/current -> generation N
#
# Avoids unrelated full E2E assertions so section 4 rebuild semantics
# can be validated independently.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Rebuild Flow Test"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
    export PATH

    if exists -f /bin/snix
        echo "FUNC_TEST:snix-exists:PASS"
    else
        echo "FUNC_TEST:snix-exists:FAIL:no-snix"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    if exists -f /etc/redox-system/manifest.json
        echo "FUNC_TEST:manifest-exists:PASS"
    else
        echo "FUNC_TEST:manifest-exists:FAIL:no-manifest"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    /nix/system/profile/bin/bash -c '
        count=$(ls /etc/redox-system/generations 2>/dev/null | wc -l || echo 0)
        echo "$count" > /tmp/pre_gen_count
        cfg=/etc/redox-system/configuration.nix
        if [ -f "$cfg" ] && grep -q "hostname" "$cfg"; then
            sed -i "s/hostname = \"[^\"]*\"/hostname = \"rebuild-proof-host\"/" "$cfg"
            if grep -q "rebuild-proof-host" "$cfg"; then
                echo FUNC_TEST:config-modified:PASS
            else
                echo "FUNC_TEST:config-modified:FAIL:sed-did-not-update"
            fi
        else
            echo "FUNC_TEST:config-modified:FAIL:no-hostname-entry"
        fi
    '

    /bin/snix system rebuild > /tmp/rebuild-proof-out ^> /tmp/rebuild-proof-err

    /nix/system/profile/bin/bash -c '
        if grep -q "rebuilt from" /tmp/rebuild-proof-out 2>/dev/null || \
           grep -q "Switched to generation" /tmp/rebuild-proof-out 2>/dev/null; then
            echo FUNC_TEST:rebuild-succeeds:PASS
        else
            echo "FUNC_TEST:rebuild-succeeds:FAIL:no-success-message"
            echo "DEBUG stdout:"
            cat /tmp/rebuild-proof-out 2>/dev/null || true
            echo "DEBUG stderr:"
            cat /tmp/rebuild-proof-err 2>/dev/null || true
        fi
    '

    /nix/system/profile/bin/bash -c '
        if [ -f /etc/hostname ] && [ "$(cat /etc/hostname)" = "rebuild-proof-host" ]; then
            echo FUNC_TEST:hostname-file-updated:PASS
        else
            actual=$(cat /etc/hostname 2>/dev/null || echo missing)
            echo "FUNC_TEST:hostname-file-updated:FAIL:actual=$actual"
        fi

        if grep -q "rebuild-proof-host" /etc/redox-system/manifest.json 2>/dev/null; then
            echo FUNC_TEST:manifest-hostname-updated:PASS
        else
            echo "FUNC_TEST:manifest-hostname-updated:FAIL:missing-hostname"
        fi
    '

    /nix/system/profile/bin/bash -c '
        pre=$(cat /tmp/pre_gen_count 2>/dev/null || echo 0)
        post=$(ls /etc/redox-system/generations 2>/dev/null | wc -l || echo 0)
        if [ "$post" -gt "$pre" ]; then
            echo FUNC_TEST:generation-count-advanced:PASS
        else
            echo "FUNC_TEST:generation-count-advanced:FAIL:pre=$pre post=$post"
        fi

        gen_id=$(grep -m1 "\"id\"" /etc/redox-system/manifest.json | sed -E "s/[^0-9]*([0-9]+).*/\\1/")
        gen_dir="/etc/redox-system/generations/$gen_id"

        if [ -n "$gen_id" ] && [ -d "$gen_dir" ]; then
            echo FUNC_TEST:generation-dir-exists:PASS
        else
            echo "FUNC_TEST:generation-dir-exists:FAIL:gen_id=$gen_id"
        fi

        if [ -f "$gen_dir/manifest.json" ] && [ -f "$gen_dir/metadata.json" ]; then
            echo FUNC_TEST:generation-artifacts-exist:PASS
        else
            echo "FUNC_TEST:generation-artifacts-exist:FAIL:missing-files"
            ls -la "$gen_dir" 2>/dev/null || true
        fi

        if [ -f "$gen_dir/metadata.json" ] && \
           grep -q "\"id\"" "$gen_dir/metadata.json" && \
           grep -q "\"description\"" "$gen_dir/metadata.json" && \
           grep -q "\"timestamp\"" "$gen_dir/metadata.json"; then
            echo FUNC_TEST:generation-metadata-valid:PASS
        else
            echo "FUNC_TEST:generation-metadata-valid:FAIL:bad-metadata"
            cat "$gen_dir/metadata.json" 2>/dev/null || true
        fi

        if [ -L /nix/system/current ]; then
            if ls -ld /nix/system/current 2>/dev/null | grep -q "$gen_dir"; then
                echo FUNC_TEST:current-link-updated:PASS
            else
                echo "FUNC_TEST:current-link-updated:FAIL:bad-target"
                ls -ld /nix/system/current 2>/dev/null || true
            fi
        else
            echo "FUNC_TEST:current-link-updated:FAIL:not-a-symlink"
        fi

        /bin/snix system generations > /tmp/rebuild-generations-out 2>/tmp/rebuild-generations-err
        if [ -f /tmp/rebuild-generations-out ] && grep -q "$gen_id" /tmp/rebuild-generations-out; then
            echo FUNC_TEST:generations-list-shows-new-gen:PASS
        else
            echo "FUNC_TEST:generations-list-shows-new-gen:FAIL:missing-gen-$gen_id"
            cat /tmp/rebuild-generations-out 2>/dev/null || true
            cat /tmp/rebuild-generations-err 2>/dev/null || true
        fi
    '

    echo '{ "hostname": "rebuild-proof-host", "packages": ["ripgrep"] }' > /tmp/rebuild-packages.json
    /bin/snix system rebuild --config /tmp/rebuild-packages.json > /tmp/rebuild-packages-out ^> /tmp/rebuild-packages-err

    /nix/system/profile/bin/bash -c '
        if grep -q "rebuilt from" /tmp/rebuild-packages-out 2>/dev/null || \
           grep -q "Switched to generation" /tmp/rebuild-packages-out 2>/dev/null; then
            echo FUNC_TEST:auto-route-package-rebuild:PASS
        else
            echo "FUNC_TEST:auto-route-package-rebuild:FAIL:no-success-message"
            cat /tmp/rebuild-packages-out 2>/dev/null || true
            cat /tmp/rebuild-packages-err 2>/dev/null || true
        fi

        if grep -q '"name": "ripgrep"' /etc/redox-system/manifest.json 2>/dev/null; then
            echo FUNC_TEST:auto-route-package-manifest:PASS
        else
            echo "FUNC_TEST:auto-route-package-manifest:FAIL:no-ripgrep"
            cat /etc/redox-system/manifest.json 2>/dev/null || true
        fi

        if [ -x /nix/system/profile/bin/rg ]; then
            echo FUNC_TEST:auto-route-package-profile:PASS
        else
            echo "FUNC_TEST:auto-route-package-profile:FAIL:missing-rg"
            ls -la /nix/system/profile/bin 2>/dev/null || true
        fi
    '

    /nix/system/profile/bin/bash -c '
        cp /etc/redox-system/manifest.json /tmp/reboot-manifest.json
        if grep -q "\"initfs\"" /tmp/reboot-manifest.json; then
            sed -i "0,/\"initfs\": \"[^\"]*\"/s//\"initfs\": \"\/nix\/store\/reboot-proof-initfs\/boot\/initfs\"/" /tmp/reboot-manifest.json
            if grep -q "reboot-proof-initfs" /tmp/reboot-manifest.json; then
                echo FUNC_TEST:boot-manifest-modified:PASS
            else
                echo "FUNC_TEST:boot-manifest-modified:FAIL:sed-did-not-update"
            fi
        else
            echo "FUNC_TEST:boot-manifest-modified:FAIL:no-initfs-entry"
        fi
    '

    /bin/snix system switch /tmp/reboot-manifest.json -D boot-path-change > /tmp/reboot-switch-out ^> /tmp/reboot-switch-err

    /nix/system/profile/bin/bash -c '
        if grep -q "Reboot recommended" /tmp/reboot-switch-out 2>/dev/null; then
            echo FUNC_TEST:reboot-warning-reported:PASS
        else
            echo "FUNC_TEST:reboot-warning-reported:FAIL:no-warning"
            cat /tmp/reboot-switch-out 2>/dev/null || true
            cat /tmp/reboot-switch-err 2>/dev/null || true
        fi
    '

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    systemPackages =
      opt "ion"
      ++ opt "uutils"
      ++ opt "extrautils"
      ++ opt "snix"
      ++ opt "redox-bash"
      ++ opt "redox-sed";

    binaryCachePackages = lib.optionalAttrs (pkgs ? ripgrep) { ripgrep = pkgs.ripgrep; };
  };

  "/networking" = {
    enable = false;
    mode = "none";
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
