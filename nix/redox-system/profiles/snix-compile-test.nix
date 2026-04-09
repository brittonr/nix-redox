# Focused snix self-compile test profile
#
# Boots the self-hosting image and runs only the snix self-compile checks.
# This avoids burning the full self-hosting timeout budget on the 70 earlier
# smoke tests before we even reach the self-compile phase.

{ pkgs, lib }:

let
  opt = name: if pkgs ? ${name} then [ pkgs.${name} ] else [ ];

  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };

  testScript = ''
                        let PATH = "/nix/system/profile/bin:/bin:/usr/bin"
                        export PATH

                        echo ""
                        echo "========================================"
                        echo "  RedoxOS snix Self-Compile Test"
                        echo "========================================"
                        echo ""
                        echo "FUNC_TESTS_START"
                        echo ""

                        if exists -f /usr/src/snix-redox/build.nix
                          echo "FUNC_TEST:snix-src-present:PASS"
                        else
                          echo "FUNC_TEST:snix-src-present:FAIL:/usr/src/snix-redox/build.nix missing"
                        end

                        if exists -d /usr/src/snix-redox/vendor
                          echo "FUNC_TEST:snix-vendor-present:PASS"
                        else
                          echo "FUNC_TEST:snix-vendor-present:FAIL:/usr/src/snix-redox/vendor missing"
                        end

                        if exists -f /nix/system/profile/bin/ld.lld
                          echo "FUNC_TEST:lld-exists:PASS"
                        else
                          echo "FUNC_TEST:lld-exists:FAIL:ld.lld missing from profile"
                        end

                        echo "--- snix self-compile: snix build --file ---"
                        /nix/system/profile/bin/bash -c '
                          export PATH=/nix/system/profile/bin:/bin:/usr/bin
                          export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
                          export CARGO_HOME=/root/.cargo
                          export CARGO_BUILD_JOBS=1
                          export CARGO_INCREMENTAL=0
                          export RAYON_NUM_THREADS=4
                          export RUST_BACKTRACE=1
                          rm -f /tmp/.cc-wrapper-raw-args /tmp/.cc-wrapper-stderr /tmp/.cc-wrapper-shared-cmd /tmp/.cc-wrapper-last-err /tmp/snix-compile-output /tmp/snix-compile-err 2>/dev/null
                          : > /tmp/snix-compile-output
                          : > /tmp/snix-compile-err

                          latest_progress() {
                            local last=""
                            while IFS= read -r line; do
                              case "$line" in
                                *"Compiling "*|*"Finished "*|*"Running "*|*"warning:"*|*"error:"*|*"build complete"*)
                                  last="$line"
                                  ;;
                              esac
                            done < /tmp/snix-compile-err
                            printf "%s" "$last"
                          }

                          /bin/snix build --file /usr/src/snix-redox/build.nix > /tmp/snix-compile-output 2> /tmp/snix-compile-err &
                          SNIX_PID=$!
                          echo "[snix-compile] started pid=$SNIX_PID heartbeat=60s"

                          while kill -0 "$SNIX_PID" 2>/dev/null; do
                            sleep 60
                            if ! kill -0 "$SNIX_PID" 2>/dev/null; then
                              break
                            fi
                            OUT_BYTES=$(wc -c < /tmp/snix-compile-output 2>/dev/null)
                            ERR_BYTES=$(wc -c < /tmp/snix-compile-err 2>/dev/null)
                            LAST=$(latest_progress 2>/dev/null)
                            if [ -n "$LAST" ]; then
                              echo "[snix-compile] heartbeat elapsed=''${SECONDS}s stdout=''${OUT_BYTES}B stderr=''${ERR_BYTES}B last=$LAST"
                            else
                              echo "[snix-compile] heartbeat elapsed=''${SECONDS}s stdout=''${OUT_BYTES}B stderr=''${ERR_BYTES}B"
                            fi
                          done

                          wait "$SNIX_PID"
                          EXIT=$?
                          OUTPUT=$(cat /tmp/snix-compile-output 2>/dev/null)
                          printf "%s\n" "$OUTPUT" > /tmp/snix-compile-output
                          echo "snix-compile-exit=$EXIT"
                          echo "snix-compile-output=$OUTPUT"
                        '

                        /nix/system/profile/bin/bash -c '
                          OUTPUT=$(cat /tmp/snix-compile-output 2>/dev/null)
                          if [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/snix" ]; then
                            echo "FUNC_TEST:snix-compile:PASS"
                            case "$OUTPUT" in
                              /nix/store/*) echo "  output in store: $OUTPUT" ;;
                              *) echo "  WARNING: output not in /nix/store: $OUTPUT" ;;
                            esac
                          else
                            echo "FUNC_TEST:snix-compile:FAIL:exit or no binary at $OUTPUT/bin/snix"
                            echo "=== snix build stderr ==="
                            cat /tmp/snix-compile-err 2>/dev/null
                            echo "=== cc-wrapper-raw-args ==="
                            cat /tmp/.cc-wrapper-raw-args 2>/dev/null
                            echo "=== cc-wrapper-stderr (lld errors) ==="
                            cat /tmp/.cc-wrapper-stderr 2>/dev/null
                            echo "=== cc-wrapper-last-err ==="
                            cat /tmp/.cc-wrapper-last-err 2>/dev/null
                            echo "=== end stderr ==="
                          fi
                        '

                        /nix/system/profile/bin/bash -c '
                          OUTPUT=$(cat /tmp/snix-compile-output 2>/dev/null)
                          SNIX_BIN="$OUTPUT/bin/snix"

                          if [ -x "$SNIX_BIN" ]; then
                            echo "FUNC_TEST:snix-binary-exists:PASS"

                            "$SNIX_BIN" --version > /tmp/snix-selfbuilt-out 2>/tmp/snix-selfbuilt-err
                            if [ $? -eq 0 ]; then
                              echo "FUNC_TEST:snix-binary-runs:PASS"
                              cat /tmp/snix-selfbuilt-out
                            else
                              echo "FUNC_TEST:snix-binary-runs:FAIL:exit $?"
                              cat /tmp/snix-selfbuilt-err
                            fi

                            EVAL_RESULT=$("$SNIX_BIN" eval --expr "1 + 1" 2>/tmp/snix-selfbuilt-eval-err)
                            if [ $? -eq 0 ] && [ "$EVAL_RESULT" = "2" ]; then
                              echo "FUNC_TEST:snix-eval-works:PASS"
                            else
                              echo "FUNC_TEST:snix-eval-works:FAIL:expected 2, got $EVAL_RESULT"
                              cat /tmp/snix-selfbuilt-eval-err
                            fi
                          else
                            echo "FUNC_TEST:snix-binary-exists:FAIL:binary not produced"
                            echo "FUNC_TEST:snix-binary-runs:FAIL:no binary"
                            echo "FUNC_TEST:snix-eval-works:FAIL:no binary"
                          fi
                        '

                        echo ""
                        echo "FUNC_TESTS_COMPLETE"
                      '';
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
      );
  };
}
