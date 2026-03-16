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

          # ── Test: waitpid stress (isolate waitpid reliability) ─────────
          echo "--- waitpid-stress ---"
          /nix/system/profile/bin/waitpid-stress 50

          # ── Test: JOBS=1 baseline (should always pass) ─────────────────
          echo "--- parallel-jobs1-baseline ---"
          /nix/system/profile/bin/bash -c '
            mkdir -p /tmp/test-parallel
            cd /tmp/test-parallel
            export CARGO_HOME=/tmp/cargo-home-j1
            mkdir -p $CARGO_HOME
            cp /root/.cargo/config.toml $CARGO_HOME/config.toml 2>/dev/null || true

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

          # ── Test: JOBS=2 single crate ──────────────────────────────────
          echo "--- parallel-jobs2-build ---"
          /nix/system/profile/bin/bash -c '
            mkdir -p /tmp/test-parallel2
            cd /tmp/test-parallel2
            export CARGO_HOME=/tmp/cargo-home-j2
            mkdir -p $CARGO_HOME
            cp /root/.cargo/config.toml $CARGO_HOME/config.toml 2>/dev/null || true

            cat > Cargo.toml << TOMLEOF
      [package]
      name = "parallel-test2"
      version = "0.1.0"
      edition = "2021"
    TOMLEOF

            mkdir -p src
            echo "fn main() { println!(\"hello parallel\"); }" > src/main.rs

            export CARGO_BUILD_JOBS=2
            export CARGO_DIAG_LOG=/tmp/cargo-diag-j2.log
            cargo build --offline > /tmp/j2-out 2>&1 &
            PID=$!
            SECONDS=0
            TIMEOUT=300
            while kill -0 $PID 2>/dev/null; do
              if [ $SECONDS -ge $TIMEOUT ]; then
                echo "FUNC_TEST:parallel-jobs2-build:FAIL:timeout after ''${TIMEOUT}s (PID=$PID)"
                echo "  proc-dump:"
                proc-dump /tmp/proc-dump-j2.log 2>/dev/null
                cat /tmp/proc-dump-j2.log 2>/dev/null | head -40
                echo "  cargo heartbeat:"
                cat /tmp/cargo-diag-j2.log 2>/dev/null | head -20
                echo "  build output:"
                cat /tmp/j2-out 2>/dev/null | head -30
                kill $PID 2>/dev/null; wait $PID 2>/dev/null
                kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
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

          # ── Graduated workspace tests at JOBS=2 ───────────────────────
          # Test workspaces of increasing size to find the hang threshold.
          # Each crate depends on the previous one (chain dependency) to
          # force sequential-ish compilation with parallel opportunities.
          /nix/system/profile/bin/bash -c '
            run_workspace_test() {
              local SIZE=$1
              local TIMEOUT=$2
              local TEST_NAME="parallel-jobs2-ws$SIZE"
              local DIR="/tmp/test-ws$SIZE"
              local CARGO_HOME_DIR="/tmp/cargo-home-ws$SIZE"
              local DIAG_LOG="/tmp/cargo-diag-ws$SIZE.log"
              local BUILD_LOG="/tmp/ws$SIZE-out.log"
              local DUMP_LOG="/tmp/proc-dump-ws$SIZE.log"

              echo "--- $TEST_NAME ---"

              mkdir -p "$DIR"
              cd "$DIR"
              export CARGO_HOME="$CARGO_HOME_DIR"
              mkdir -p "$CARGO_HOME"
              cp /root/.cargo/config.toml "$CARGO_HOME/config.toml" 2>/dev/null || true

              # Generate workspace Cargo.toml — all independent binary crates
              # so JOBS=2 actually runs two compilations in parallel
              echo "[workspace]" > Cargo.toml
              echo "resolver = \"2\"" >> Cargo.toml
              printf "members = [" >> Cargo.toml
              for ((i=1; i<=SIZE; i++)); do
                if [ $i -gt 1 ]; then printf ", " >> Cargo.toml; fi
                printf "\"crate-%03d\"" "$i" >> Cargo.toml
              done
              echo "]" >> Cargo.toml

              # Each crate is an independent binary — no inter-crate deps
              # This maximizes parallelism: with JOBS=2, two rustc+lld run concurrently
              for ((i=1; i<=SIZE; i++)); do
                local CNAME=$(printf "crate-%03d" "$i")
                mkdir -p "$CNAME/src"
                echo "[package]" > "$CNAME/Cargo.toml"
                echo "name = \"$CNAME\"" >> "$CNAME/Cargo.toml"
                echo "version = \"0.1.0\"" >> "$CNAME/Cargo.toml"
                echo "edition = \"2021\"" >> "$CNAME/Cargo.toml"
                echo "fn main() { println!(\"ws''${SIZE} crate $i\"); }" > "$CNAME/src/main.rs"
              done

              export CARGO_BUILD_JOBS=2
              export CARGO_DIAG_LOG="$DIAG_LOG"
              cargo build --offline > "$BUILD_LOG" 2>&1 &
              PID=$!
              SECONDS=0

              while kill -0 $PID 2>/dev/null; do
                if [ $SECONDS -ge $TIMEOUT ]; then
                  echo "FUNC_TEST:$TEST_NAME:FAIL:timeout after ''${TIMEOUT}s"
                  # Capture diagnostics before killing
                  proc-dump "$DUMP_LOG" 2>/dev/null
                  echo "  === proc-dump ==="
                  cat "$DUMP_LOG" 2>/dev/null | head -60
                  echo "  === cargo heartbeat (last 20 lines) ==="
                  cat "$DIAG_LOG" 2>/dev/null | head -20
                  echo "  === build output (last 30 lines) ==="
                  cat "$BUILD_LOG" 2>/dev/null | head -30
                  kill $PID 2>/dev/null; wait $PID 2>/dev/null
                  kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
                  rm -rf "$DIR" "$CARGO_HOME_DIR"
                  return 1
                fi
                cat /scheme/sys/uname > /dev/null 2>&1
              done
              wait $PID
              BUILD_RC=$?

              if [ $BUILD_RC -eq 0 ]; then
                echo "FUNC_TEST:$TEST_NAME:PASS"
                echo "  JOBS=2 ws$SIZE build completed in ''${SECONDS}s"
              else
                echo "FUNC_TEST:$TEST_NAME:FAIL:exit=$BUILD_RC"
                cat "$BUILD_LOG" 2>/dev/null | head -30
                echo "  === cargo heartbeat ==="
                cat "$DIAG_LOG" 2>/dev/null | head -20
              fi
              rm -rf "$DIR" "$CARGO_HOME_DIR"
              return $BUILD_RC
            }

            # Graduated sizes with appropriate timeouts
            run_workspace_test 5 120
            run_workspace_test 10 120
            run_workspace_test 20 300
            run_workspace_test 50 300
            run_workspace_test 100 600
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

  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = testScript;
  };

  "/environment" = selfHosting."/environment" // {
    systemPackages =
      builtins.filter (p: !(pkgs ? userutils && toString p == toString pkgs.userutils)) (
        selfHosting."/environment".systemPackages or [ ]
      )
      ++ opt "proc-dump"
      ++ opt "waitpid-stress";
  };
}
