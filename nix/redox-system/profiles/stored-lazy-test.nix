# Stored Lazy Extraction Test Profile for RedoxOS
#
# Proves the `stored` daemon can serve a lazy-installed package via the
# `store:` scheme and materialize it into /nix/store on first access.
#
# Test protocol:
#   FUNC_TESTS_START              → suite starting
#   FUNC_TEST:<name>:PASS         → test passed
#   FUNC_TEST:<name>:FAIL:<reason>→ test failed
#   FUNC_TESTS_COMPLETE           → suite finished

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
    echo ""
    echo "========================================"
    echo "  RedoxOS Stored Lazy Extraction Test"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
    export PATH

    if exists -f /bin/stored
        echo "FUNC_TEST:stored-binary-present:PASS"
    else
        echo "FUNC_TEST:stored-binary-present:FAIL:/bin/stored missing"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    ls /usr/lib/init.d/*stored.service > /tmp/stored-unit-list ^> /tmp/stored-unit-list-err
    if test $? = 0
        grep "/bin/stored" /usr/lib/init.d/*stored.service > /dev/null ^> /dev/null
        let unit_cmd_ok = $?
        grep "notify" /usr/lib/init.d/*stored.service > /dev/null ^> /dev/null
        let unit_type_ok = $?
        if test $unit_cmd_ok = 0
            if test $unit_type_ok = 0
                echo "FUNC_TEST:stored-service-unit:PASS"
            else
                echo "FUNC_TEST:stored-service-unit:FAIL:wrong-type"
                echo ""
                echo "FUNC_TESTS_COMPLETE"
                echo ""
                exit
            end
        else
            echo "FUNC_TEST:stored-service-unit:FAIL:wrong-command"
            echo ""
            echo "FUNC_TESTS_COMPLETE"
            echo ""
            exit
        end
    else
        echo "FUNC_TEST:stored-service-unit:FAIL:missing-unit"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    grep '"store"' /etc/login_schemes.toml > /dev/null ^> /dev/null
    if test $? = 0
        echo "FUNC_TEST:login-schemes-has-store:PASS"
    else
        echo "FUNC_TEST:login-schemes-has-store:FAIL:missing-store"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    # Wait for stored to register.
    let stored_ready = 0
    let wait_count = 0
    while test $wait_count -lt 500
        ls /scheme/store/ > /tmp/store-root-ls ^> /tmp/store-root-err
        if test $? = 0
            let stored_ready = 1
            break
        end
        let wait_count += 1
    end

    if test $stored_ready = 1
        echo "FUNC_TEST:stored-auto-started:PASS"
    else
        echo "FUNC_TEST:stored-auto-started:FAIL:ls-store-root"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    /bin/snix install --lazy ripgrep > /tmp/install-rg-out ^> /tmp/install-rg-err
    if test $? = 0
        echo "FUNC_TEST:lazy-install-ripgrep:PASS"
    else
        echo "FUNC_TEST:lazy-install-ripgrep:FAIL:install-error"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    ls /scheme/store/ > /tmp/store-root-after-install ^> /tmp/store-root-after-install-err
    if test $? != 0
        echo "FUNC_TEST:store-root-after-install:FAIL:ls-error"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    let rg_name = ""
    grep "ripgrep" /tmp/store-root-after-install > /tmp/rg-name ^> /tmp/rg-name-err
    if test $? = 0
        let rg_name = $(cat /tmp/rg-name)
        echo "FUNC_TEST:store-path-name-found:PASS"
    else
        echo "FUNC_TEST:store-path-name-found:FAIL:missing-from-store-root"
        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
        exit
    end

    if not exists -f /nix/store/$rg_name/bin/rg
        echo "FUNC_TEST:lazy-install-not-yet-extracted:PASS"
    else
        echo "FUNC_TEST:lazy-install-not-yet-extracted:FAIL:file-already-present"
    end

    cat store:$rg_name/bin/rg > /tmp/rg-via-store-literal ^> /tmp/rg-via-store-literal-err
    if test $? = 0
        let rg_size = $(wc -c < /tmp/rg-via-store-literal)
        if test $rg_size -gt 0
            echo "FUNC_TEST:store-scheme-literal-file-read:PASS"
        else
            echo "FUNC_TEST:store-scheme-literal-file-read:FAIL:zero-bytes"
        end
    else
        echo "FUNC_TEST:store-scheme-literal-file-read:FAIL:cat-error"
    end

    cat /scheme/store/$rg_name/bin/rg > /tmp/rg-via-store ^> /tmp/rg-via-store-err
    if test $? = 0
        let rg_size = $(wc -c < /tmp/rg-via-store)
        if test $rg_size -gt 0
            echo "FUNC_TEST:store-scheme-file-read:PASS"
        else
            echo "FUNC_TEST:store-scheme-file-read:FAIL:zero-bytes"
        end
    else
        echo "FUNC_TEST:store-scheme-file-read:FAIL:cat-error"
    end

    if exists -f /nix/store/$rg_name/bin/rg
        echo "FUNC_TEST:lazy-read-materialized-store-path:PASS"
    else
        echo "FUNC_TEST:lazy-read-materialized-store-path:FAIL:not-materialized"
    end

    ls /scheme/store/$rg_name/ > /tmp/store-rg-root ^> /tmp/store-rg-root-err
    if test $? = 0
        grep "bin" /tmp/store-rg-root > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:store-scheme-readdir-store-root:PASS"
        else
            echo "FUNC_TEST:store-scheme-readdir-store-root:FAIL:missing-bin"
        end
    else
        echo "FUNC_TEST:store-scheme-readdir-store-root:FAIL:ls-error"
    end

    ls /scheme/store/$rg_name/bin/ > /tmp/store-rg-bin ^> /tmp/store-rg-bin-err
    if test $? = 0
        grep "rg" /tmp/store-rg-bin > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:store-scheme-readdir-bin:PASS"
        else
            echo "FUNC_TEST:store-scheme-readdir-bin:FAIL:missing-rg"
        end
    else
        echo "FUNC_TEST:store-scheme-readdir-bin:FAIL:ls-error"
    end

    ls -ld /scheme/store/$rg_name/bin/rg > /tmp/store-rg-stat ^> /tmp/store-rg-stat-err
    if test $? = 0
        grep "rg" /tmp/store-rg-stat > /dev/null ^> /dev/null
        if test $? = 0
            echo "FUNC_TEST:store-scheme-stat-file:PASS"
        else
            echo "FUNC_TEST:store-scheme-stat-file:FAIL:missing-rg"
        end
    else
        echo "FUNC_TEST:store-scheme-stat-file:FAIL:ls-error"
    end

    cat /scheme/store/$rg_name/bin/rg > /tmp/rg-via-store-2 ^> /tmp/rg-via-store-2-err
    if test $? = 0
        let rg_size2 = $(wc -c < /tmp/rg-via-store-2)
        if test $rg_size2 -gt 0
            echo "FUNC_TEST:store-scheme-second-open-read:PASS"
        else
            echo "FUNC_TEST:store-scheme-second-open-read:FAIL:zero-bytes"
        end
    else
        echo "FUNC_TEST:store-scheme-second-open-read:FAIL:cat-error"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
    echo ""
  '';
in
{
  "/environment" = {
    systemPackages = opt "ion" ++ opt "uutils" ++ opt "extrautils" ++ opt "snix" ++ opt "stored";
    binaryCachePackages = lib.optionalAttrs (pkgs ? ripgrep) { ripgrep = pkgs.ripgrep; };
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

  "/snix" = {
    stored = {
      enable = true;
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
