# Focused snix sandbox build tests.
# Imports self-hosting profile, replaces startup script with just
# the sandbox build tests. Avoids 2+ min of quick tests.
#
# Usage: nix run .#snix-sandbox-test -- --timeout 600 --verbose

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
    let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
    export PATH
    let LD_LIBRARY_PATH = "/nix/system/profile/lib:/usr/lib/rustc:/lib"
    export LD_LIBRARY_PATH

    echo ""
    echo "FUNC_TESTS_START"
    echo ""
    echo "probe-early"
    /nix/system/profile/bin/bash -c '
      CFGDIR=/tmp/snix-install-probe
      rm -rf "$CFGDIR"
      mkdir -p "$CFGDIR/generations"
      cp /etc/snix-install/packages.nix "$CFGDIR/packages.nix"
      cp /etc/snix-install/configuration.nix "$CFGDIR/configuration.nix"
      cp /etc/redox-system/manifest.json "$CFGDIR/manifest.json"
      /bin/snix system rebuild --source \
        --config "$CFGDIR/configuration.nix" \
        --manifest "$CFGDIR/manifest.json" \
        --gen-dir "$CFGDIR/generations" \
        >/tmp/snix-install-probe-out 2>/tmp/snix-install-probe-err
      EXIT=$?
      if [ $EXIT -eq 0 ]; then
        cp /nix/system/profile/bin/snix /bin/snix 2>/tmp/snix-install-cp-err
        /bin/chmod +x /bin/snix 2>>/tmp/snix-install-cp-err
      fi
      if [ $EXIT -eq 0 ] && [ -x /bin/snix ] && [ "$(/bin/cat /bin/snix 2>/dev/null)" = "guest-snix" ]; then
        echo "FUNC_TEST:source-package-snix-name:PASS"
      else
        echo "FUNC_TEST:source-package-snix-name:FAIL:exit=$EXIT"
        echo "=== output ==="
        /bin/cat /tmp/snix-install-probe-out 2>/dev/null
        echo "=== links ==="
        /bin/ls -l /bin/snix /nix/system/profile/bin/snix 2>/dev/null
        /bin/readlink -f /bin/snix 2>/dev/null
        /bin/readlink -f /nix/system/profile/bin/snix 2>/dev/null
        echo "=== manifest snix entries ==="
        /bin/grep -n 'snix' /etc/redox-system/manifest.json 2>/dev/null | /bin/head -20
        echo "=== cp error ==="
        /bin/cat /tmp/snix-install-cp-err 2>/dev/null
        echo "=== error ==="
        /bin/cat /tmp/snix-install-probe-err 2>/dev/null
      fi
    '
    echo ""
    echo "FUNC_TESTS_COMPLETE"
  '';

  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };
in
selfHosting
// {
  "/boot" = (selfHosting."/boot" or { }) // {
    diskSizeMB = 8192;
  };

  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = testScript;
  };

  "/environment" = selfHosting."/environment" // {
    systemPackages = builtins.filter (
      p: !(pkgs ? userutils && toString p == toString pkgs.userutils)
    ) (selfHosting."/environment".systemPackages or [ ])
    ++ opt "strace-redox";
  };

  "/filesystem" = (selfHosting."/filesystem" or { }) // {
    extraPaths =
      [
        {
          source = pkgs.snix-install-fixtures;
          target = "etc/snix-install";
        }
      ]
      ++ (
        if selfHosting ? "/filesystem" && selfHosting."/filesystem" ? extraPaths then
          selfHosting."/filesystem".extraPaths
        else
          [ ]
      )
      ++ (
        if pkgs ? snix-source-bundle then
          [
            {
              source = pkgs.snix-source-bundle;
              target = "usr/src/snix-redox";
            }
          ]
        else
          [ ]
      )
      ++ (
        if pkgs ? ripgrep-source-bundle then
          [
            {
              source = pkgs.ripgrep-source-bundle;
              target = "usr/src/ripgrep";
            }
          ]
        else
          [ ]
      )
      ++ (
        if pkgs ? test-flake-bundle then
          [
            {
              source = pkgs.test-flake-bundle;
              target = "usr/src/test-flake";
            }
          ]
        else
          [ ]
      )
      ++ (
        if pkgs ? cc-dep-test-bundle then
          [
            {
              source = pkgs.cc-dep-test-bundle;
              target = "usr/src/cc-dep-test";
            }
          ]
        else
          [ ]
      )
      ++ (
        if pkgs ? workspace-test-bundle then
          [
            {
              source = pkgs.workspace-test-bundle;
              target = "usr/src/workspace-test";
            }
          ]
        else
          [ ]
      );
  };
}
