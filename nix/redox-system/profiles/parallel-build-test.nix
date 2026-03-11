# Parallel Build Test Profile for RedoxOS
#
# Tests whether cargo can build with JOBS>1 without hanging.
# Based on the self-hosting profile but with a smaller test project
# and a hard timeout to prevent the test from blocking CI.
#
# Test protocol:
#   FUNC_TESTS_START              → suite starting
#   FUNC_TEST:<name>:PASS         → test passed
#   FUNC_TEST:<name>:FAIL:<reason>→ test failed
#   FUNC_TEST:<name>:SKIP         → test skipped
#   FUNC_TESTS_COMPLETE           → suite finished
#
# The parallel build is expected to fail/hang on current Redox.
# This profile is used for investigation — capturing where the hang occurs.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  testScript = ''
        echo ""
        echo "========================================"
        echo "  RedoxOS Parallel Build Test Suite"
        echo "========================================"
        echo ""
        echo "FUNC_TESTS_START"
        echo ""

        # ── Test: JOBS=1 baseline (should always pass) ─────────────────
        echo "--- parallel-jobs1-baseline ---"
        /nix/system/profile/bin/bash -c '
          mkdir -p /tmp/test-parallel
          cd /tmp/test-parallel
          export CARGO_HOME=/tmp/cargo-home-j1
          mkdir -p $CARGO_HOME

          cat > Cargo.toml << TOMLEOF
    [package]
    name = "parallel-test"
    version = "0.1.0"
    edition = "2021"
    TOMLEOF

          mkdir -p src
          echo "fn main() { println!(\"hello\"); }" > src/main.rs

          export CARGO_BUILD_JOBS=1
          timeout_rc=0
          cargo build --offline > /tmp/j1-out 2>&1 &
          PID=$!
          SECONDS=0
          while kill -0 $PID 2>/dev/null; do
            if [ $SECONDS -ge 120 ]; then
              kill $PID 2>/dev/null; wait $PID 2>/dev/null
              kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
              timeout_rc=124
              break
            fi
            cat /scheme/sys/uname > /dev/null 2>&1
          done
          if [ $timeout_rc -eq 0 ]; then
            wait $PID
            BUILD_RC=$?
          else
            BUILD_RC=$timeout_rc
          fi

          if [ $BUILD_RC -eq 0 ]; then
            echo "FUNC_TEST:parallel-jobs1-baseline:PASS"
          else
            echo "FUNC_TEST:parallel-jobs1-baseline:FAIL:exit=$BUILD_RC"
            cat /tmp/j1-out 2>/dev/null | head -20
          fi
          rm -rf /tmp/test-parallel /tmp/cargo-home-j1
        '

        # ── Test: JOBS=2 (may hang — has hard timeout) ─────────────────
        echo "--- parallel-jobs2-build ---"
        /nix/system/profile/bin/bash -c '
          mkdir -p /tmp/test-parallel2
          cd /tmp/test-parallel2
          export CARGO_HOME=/tmp/cargo-home-j2
          mkdir -p $CARGO_HOME

          cat > Cargo.toml << TOMLEOF
    [package]
    name = "parallel-test2"
    version = "0.1.0"
    edition = "2021"
    TOMLEOF

          mkdir -p src
          echo "fn main() { println!(\"hello parallel\"); }" > src/main.rs

          export CARGO_BUILD_JOBS=2
          cargo build --offline > /tmp/j2-out 2>&1 &
          PID=$!
          SECONDS=0
          TIMEOUT=300
          while kill -0 $PID 2>/dev/null; do
            if [ $SECONDS -ge $TIMEOUT ]; then
              echo "FUNC_TEST:parallel-jobs2-build:FAIL:timeout after ''${TIMEOUT}s (PID=$PID)"
              echo "  Process tree at hang:"
              # On Redox, no ps command. List what we can.
              ls /scheme/proc/ 2>/dev/null | head -20
              kill $PID 2>/dev/null; wait $PID 2>/dev/null
              kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
              echo "  Build output:"
              cat /tmp/j2-out 2>/dev/null | head -30
              rm -rf /tmp/test-parallel2 /tmp/cargo-home-j2
              exit 0
            fi
            cat /scheme/sys/uname > /dev/null 2>&1
          done
          wait $PID
          BUILD_RC=$?

          if [ $BUILD_RC -eq 0 ]; then
            echo "FUNC_TEST:parallel-jobs2-build:PASS"
            echo "  JOBS=2 build completed in ''${SECONDS}s"
          else
            echo "FUNC_TEST:parallel-jobs2-build:FAIL:exit=$BUILD_RC"
            cat /tmp/j2-out 2>/dev/null | head -20
          fi
          rm -rf /tmp/test-parallel2 /tmp/cargo-home-j2
        '

        echo ""
        echo "FUNC_TESTS_COMPLETE"
        echo ""
  '';

  # Build from the self-hosting profile
  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };
in
selfHosting
// {
  "/boot" = (selfHosting."/boot" or { }) // {
    diskSizeMB = 4096;
  };

  "/snix" = {
    sandbox = false;
  };

  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = testScript;
  };

  "/environment" = selfHosting."/environment" // {
    systemPackages = builtins.filter (
      p:
      let
        name = p.pname or (builtins.parseDrvName p.name).name;
      in
      name != "userutils" && name != "redox-userutils"
    ) (selfHosting."/environment".systemPackages or [ ]);
  };
}
