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
    let CARGO_BUILD_JOBS = "2"
    export CARGO_BUILD_JOBS
    let RAYON_NUM_THREADS = "4"
    export RAYON_NUM_THREADS
    let CARGO_HOME = "/root/.cargo"
    export CARGO_HOME
    let RUST_BACKTRACE = "1"
    export RUST_BACKTRACE

    echo ""
    echo "FUNC_TESTS_START"
    echo ""
    echo "=== SNIX SANDBOX BUILD TESTS ==="
    echo ""

    # ── snix-proxy-active: proxy must be active, not fallback ──
    echo "--- snix-proxy-active ---"
    /nix/system/profile/bin/bash -c '
      OUTPUT=$(/bin/snix build --expr "derivation { name = \"proxy-active\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo proxy-active > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" 2>/tmp/proxy-active-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && grep -q "buildfs: proxy mode active" /tmp/proxy-active-err 2>/dev/null && grep -q "buildfs: entering event loop" /tmp/proxy-active-err 2>/dev/null; then
        echo "FUNC_TEST:snix-proxy-active:PASS"
      else
        echo "FUNC_TEST:snix-proxy-active:FAIL:exit=$EXIT"
        cat /tmp/proxy-active-err 2>/dev/null | head -20 >&2
      fi
    '

    echo "--- rustc-profile ---"
    /nix/system/profile/bin/bash -c '
      /nix/system/profile/bin/rustc -vV >/tmp/rustc-profile-out 2>/tmp/rustc-profile-err
      EXIT=$?
      if [ $EXIT -eq 0 ]; then
        echo "FUNC_TEST:rustc-profile:PASS"
      else
        echo "FUNC_TEST:rustc-profile:FAIL:exit=$EXIT"
        cat /tmp/rustc-profile-err 2>/dev/null >&2
      fi
    '

    echo "--- rustc-direct ---"
    /nix/system/profile/bin/bash -c '
      /usr/lib/rustc/rustc -vV >/tmp/rustc-direct-out 2>/tmp/rustc-direct-err
      EXIT=$?
      if [ $EXIT -eq 0 ]; then
        echo "FUNC_TEST:rustc-direct:PASS"
      else
        echo "FUNC_TEST:rustc-direct:FAIL:exit=$EXIT"
        cat /tmp/rustc-direct-err 2>/dev/null >&2
      fi
    '

    echo "--- rustc-proxy-profile ---"
    /nix/system/profile/bin/bash -c '
      OUTPUT=$(/bin/snix build --expr "derivation { name = \"rustc-proxy-profile\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"/nix/system/profile/bin/rustc -vV > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" 2>/tmp/rustc-proxy-profile-err)
      EXIT=$?
      if [ $EXIT -eq 0 ]; then
        echo "FUNC_TEST:rustc-proxy-profile:PASS"
      else
        echo "FUNC_TEST:rustc-proxy-profile:FAIL:exit=$EXIT"
        cat /tmp/rustc-proxy-profile-err 2>/dev/null | head -40 >&2
      fi
    '

    echo "--- rustc-proxy-probe ---"
    /nix/system/profile/bin/bash -c '
      OUTPUT=$(/bin/snix build --expr "derivation { name = \"rustc-proxy-probe\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"export HOME=/tmp; /bin/mkdir -p \\\$out && /bin/strace /nix/system/profile/bin/rustc - --crate-name ___ --print=file-names --crate-type bin --crate-type rlib --crate-type dylib --crate-type cdylib --crate-type staticlib --crate-type proc-macro --print=sysroot --print=split-debuginfo --print=crate-name --print=cfg -Wwarnings </dev/null > \\\$out/probe.out 2> /tmp/rustc-probe-trace; STATUS=\\\$?; /bin/head -80 /tmp/rustc-probe-trace >&2; exit \\\$STATUS\"]; system = \"x86_64-unknown-redox\"; }" 2>/tmp/rustc-proxy-probe-err)
      EXIT=$?
      if [ $EXIT -eq 0 ]; then
        echo "FUNC_TEST:rustc-proxy-probe:PASS"
      else
        echo "FUNC_TEST:rustc-proxy-probe:FAIL:exit=$EXIT"
        cat /tmp/rustc-proxy-probe-err 2>/dev/null | head -120 >&2
      fi
    '

    echo "--- flake-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      /bin/snix build "/usr/src/test-flake#hello"
      EXIT=$?
      if [ $EXIT -eq 0 ]; then
        echo "FUNC_TEST:flake-build:PASS"
      else
        echo "FUNC_TEST:flake-build:FAIL:exit=$EXIT"
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
      (
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
