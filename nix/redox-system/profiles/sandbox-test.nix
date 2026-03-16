# Sandbox Test Profile
#
# Validates the per-path filesystem proxy for snix builds.
# Clones self-hosting-test but with sandbox = true and runs only
# the simplest builds: snix derivations from bash scripts and a
# single cargo hello-world through snix.
#
# Test protocol (same as functional test):
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
                        echo "  RedoxOS Sandbox Test Suite"
                        echo "========================================"
                        echo ""
                        echo "FUNC_TESTS_START"
                        echo ""

                        # ── Toolchain Presence (minimal) ────────────────────────
                        if exists -f /nix/system/profile/bin/rustc
                          echo "FUNC_TEST:rustc-exists:PASS"
                        else
                          echo "FUNC_TEST:rustc-exists:FAIL:rustc not found"
                        end

                        if exists -f /nix/system/profile/bin/cargo
                          echo "FUNC_TEST:cargo-exists:PASS"
                        else
                          echo "FUNC_TEST:cargo-exists:FAIL:cargo not found"
                        end

                        if exists -f /nix/system/profile/bin/cc
                          echo "FUNC_TEST:cc-exists:PASS"
                        else
                          echo "FUNC_TEST:cc-exists:FAIL:cc not found"
                        end

                        if exists -f /bin/snix
                          echo "FUNC_TEST:snix-exists:PASS"
                        else
                          echo "FUNC_TEST:snix-exists:FAIL:snix not found"
                        end

                        # ── snix build tests (sandbox exercises the proxy) ──────
                        echo ""
                        echo "========================================"
                        echo "  SNIX BUILD TESTS (SANDBOX=ENABLED)"
                        echo "========================================"
                        echo ""

                        # ── Test: snix build simple file output ─────────────
                        echo "--- snix-build-simple: basic derivation ---"
                        /nix/system/profile/bin/bash -c '
                          mkdir -p /nix/store /nix/var/snix/pathinfo
                          echo "[snix-test] starting snix build..."
                          # Run snix with timeout: fork a background monitor that kills snix after 30s
                          /bin/snix build --expr "derivation { name = \"snix-build-test\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo snix-build-works > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" > /tmp/snix-build-simple-raw &
                          SNIX_PID=$!
                          echo "[snix-test] snix pid=$SNIX_PID"
                          # Wait up to 30 seconds
                          WAITED=0
                          while kill -0 $SNIX_PID 2>/dev/null; do
                            if [ $WAITED -ge 30 ]; then
                              echo "[snix-test] TIMEOUT: snix still running after 30s, killing"
                              kill -9 $SNIX_PID 2>/dev/null
                              wait $SNIX_PID 2>/dev/null
                              break
                            fi
                            # Scheme I/O keeps bash active so the scheduler
                            # delivers waitpid wakes (AGENTS.md poll-wait pattern).
                            cat /scheme/sys/uname > /dev/null 2>/dev/null || true
                            WAITED=$((WAITED + 1))
                          done
                          # Scheme I/O before wait to keep process active.
                          cat /scheme/sys/uname > /dev/null 2>/dev/null || true
                          wait $SNIX_PID 2>/dev/null
                          EXIT=$?
                          echo "[snix-test] exit=$EXIT"
                          cat /tmp/snix-build-simple-raw
                          OUTPUT=$(grep "^/nix/store" /tmp/snix-build-simple-raw 2>/dev/null | head -1)
                          echo "$OUTPUT" > /tmp/snix-build-simple-output
                          if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -f "$OUTPUT" ]; then
                            CONTENT=$(cat "$OUTPUT")
                            if [ "$CONTENT" = "snix-build-works" ]; then
                              echo "FUNC_TEST:snix-build-simple:PASS"
                            else
                              echo "FUNC_TEST:snix-build-simple:FAIL:wrong content: $CONTENT"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-simple:FAIL:exit=$EXIT output=$OUTPUT"
                          fi
                        '

                        # ── Test: output path is in /nix/store/ ────────────
                        echo "--- snix-build-store-path: output is a store path ---"
                        /nix/system/profile/bin/bash -c '
                          OUTPUT=$(cat /tmp/snix-build-simple-output 2>/dev/null)
                          case "$OUTPUT" in
                            /nix/store/*) echo "FUNC_TEST:snix-build-store-path:PASS" ;;
                            *) echo "FUNC_TEST:snix-build-store-path:FAIL:$OUTPUT" ;;
                          esac
                        '

                        # ── Test: snix store info shows the built path ──────
                        echo "--- snix-build-registered: output in pathinfo db ---"
                        /nix/system/profile/bin/bash -c '
                          OUTPUT=$(cat /tmp/snix-build-simple-output 2>/dev/null)
                          if [ -n "$OUTPUT" ]; then
                            INFO=$(/bin/snix store info "$OUTPUT" 2>&1)
                            if echo "$INFO" | grep -qi "sha256"; then
                              echo "FUNC_TEST:snix-build-registered:PASS"
                            else
                              echo "FUNC_TEST:snix-build-registered:FAIL:$INFO"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-registered:FAIL:no output"
                          fi
                        '

                        # ── Test: snix build directory output ───────────────
                        echo "--- snix-build-dir: directory output ---"
                        /nix/system/profile/bin/bash -c '
                          OUTPUT=$(/bin/snix build --expr "derivation { name = \"dir-test\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"export PATH=/nix/system/profile/bin:/bin:/usr/bin && mkdir -p \\\$out/bin && echo hello-from-dir > \\\$out/bin/greeting && echo 42 > \\\$out/version\"]; system = \"x86_64-unknown-redox\"; }" 2>/tmp/snix-build-dir-err)
                          EXIT=$?
                          if [ $EXIT -eq 0 ] && [ -d "$OUTPUT" ]; then
                            G=$(cat "$OUTPUT/bin/greeting" 2>/dev/null)
                            V=$(cat "$OUTPUT/version" 2>/dev/null)
                            if [ "$G" = "hello-from-dir" ] && [ "$V" = "42" ]; then
                              echo "FUNC_TEST:snix-build-dir:PASS"
                            else
                              echo "FUNC_TEST:snix-build-dir:FAIL:greeting=$G version=$V"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-dir:FAIL:exit=$EXIT"
                            cat /tmp/snix-build-dir-err 2>/dev/null
                          fi
                        '

                        # ── Test: snix build idempotent (cached) ───────────
                        echo "--- snix-build-cached: idempotent rebuild ---"
                        /nix/system/profile/bin/bash -c '
                          OUTPUT=$(/bin/snix build --expr "derivation { name = \"snix-build-test\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo snix-build-works > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" 2>/dev/null)
                          ORIG=$(cat /tmp/snix-build-simple-output 2>/dev/null)
                          if [ "$OUTPUT" = "$ORIG" ] && [ -n "$OUTPUT" ]; then
                            echo "FUNC_TEST:snix-build-cached:PASS"
                          else
                            echo "FUNC_TEST:snix-build-cached:FAIL:output=$OUTPUT orig=$ORIG"
                          fi
                        '

                        # ── Test: snix build with dependency chain ──────────
                        echo "--- snix-build-dep: dependency chain ---"
                        /nix/system/profile/bin/bash -c '
                          cat > /tmp/snix-dep-test.nix << '"'"'NIXEOF'"'"'
        let
          dep = derivation {
            name = "snix-dep";
            builder = "/nix/system/profile/bin/bash";
            args = ["-c" "echo dependency-output > $out"];
            system = "x86_64-unknown-redox";
          };
          main = derivation {
            name = "snix-main";
            builder = "/nix/system/profile/bin/bash";
            args = ["-c" "export PATH=/nix/system/profile/bin:/bin:/usr/bin; cat ''${dep} > $out; echo main-added >> $out"];
            system = "x86_64-unknown-redox";
            inherit dep;
          };
        in main
  NIXEOF

                          OUTPUT=$(/bin/snix build --file /tmp/snix-dep-test.nix 2>/tmp/snix-build-dep-err)
                          EXIT=$?
                          if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
                            CONTENT=$(cat "$OUTPUT")
                            if echo "$CONTENT" | grep -q "dependency-output" && echo "$CONTENT" | grep -q "main-added"; then
                              echo "FUNC_TEST:snix-build-dep:PASS"
                            else
                              echo "FUNC_TEST:snix-build-dep:FAIL:content=$CONTENT"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-dep:FAIL:exit=$EXIT"
                            cat /tmp/snix-build-dep-err 2>/dev/null
                          fi
                        '

                        # ── Test: snix build executable output ─────────────
                        echo "--- snix-build-exec: executable output ---"
                        /nix/system/profile/bin/bash -c '
                          cat > /tmp/snix-exec-test.nix << '"'"'NIXEOF'"'"'
        derivation {
          name = "hello-script";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "export PATH=/nix/system/profile/bin:/bin:/usr/bin; mkdir -p $out/bin; echo SNIX_BUILT_AND_RAN > $out/bin/hello"];
          system = "x86_64-unknown-redox";
        }
  NIXEOF

                          OUTPUT=$(/bin/snix build --file /tmp/snix-exec-test.nix 2>/tmp/snix-build-exec-err)
                          EXIT=$?
                          if [ $EXIT -eq 0 ] && [ -f "$OUTPUT/bin/hello" ]; then
                            CONTENT=$(cat "$OUTPUT/bin/hello")
                            if [ "$CONTENT" = "SNIX_BUILT_AND_RAN" ]; then
                              echo "FUNC_TEST:snix-build-exec:PASS"
                            else
                              echo "FUNC_TEST:snix-build-exec:FAIL:content=$CONTENT"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-exec:FAIL:exit=$EXIT"
                            cat /tmp/snix-build-exec-err 2>/dev/null
                          fi
                        '

                        # ── Test: snix build via --file ─────────────────────
                        echo "--- snix-build-file: build from .nix file ---"
                        /nix/system/profile/bin/bash -c '
                          cat > /tmp/snix-file-test.nix << '"'"'NIXEOF'"'"'
        derivation {
          name = "from-file";
          builder = "/nix/system/profile/bin/bash";
          args = ["-c" "echo built-from-nix-file > $out"];
          system = "x86_64-unknown-redox";
        }
  NIXEOF

                          OUTPUT=$(/bin/snix build --file /tmp/snix-file-test.nix 2>/tmp/snix-build-file-err)
                          EXIT=$?
                          if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
                            CONTENT=$(cat "$OUTPUT")
                            if [ "$CONTENT" = "built-from-nix-file" ]; then
                              echo "FUNC_TEST:snix-build-file:PASS"
                            else
                              echo "FUNC_TEST:snix-build-file:FAIL:content=$CONTENT"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-file:FAIL:exit=$EXIT"
                            cat /tmp/snix-build-file-err 2>/dev/null
                          fi
                        '

                        # ── Test: snix build failing builder ───────────────
                        echo "--- snix-build-fail: builder failure handled ---"
                        /nix/system/profile/bin/bash -c '
                          /bin/snix build --expr "derivation { name = \"will-fail\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo failing >&2 && exit 42\"]; system = \"x86_64-unknown-redox\"; }" >/dev/null 2>/tmp/snix-build-fail-err
                          EXIT=$?
                          if [ $EXIT -ne 0 ]; then
                            if grep -qi "fail" /tmp/snix-build-fail-err 2>/dev/null; then
                              echo "FUNC_TEST:snix-build-fail:PASS"
                            elif grep -qi "error" /tmp/snix-build-fail-err 2>/dev/null; then
                              echo "FUNC_TEST:snix-build-fail:PASS"
                            elif grep -qi "builder" /tmp/snix-build-fail-err 2>/dev/null; then
                              echo "FUNC_TEST:snix-build-fail:PASS"
                            else
                              echo "FUNC_TEST:snix-build-fail:FAIL:no error message"
                              cat /tmp/snix-build-fail-err
                            fi
                          else
                            echo "FUNC_TEST:snix-build-fail:FAIL:should have failed"
                          fi
                        '

                        # ── Test: snix build compiles a Rust crate ─────────
                        # A Nix derivation that runs cargo build to compile a Rust
                        # hello-world, producing a real ELF binary in /nix/store/.
                        # This is the simplest cargo build through the sandbox proxy.
                        echo ""
                        echo "--- snix-build-cargo: Rust hello-world in Nix derivation ---"
                        /nix/system/profile/bin/bash -c '
                          cat > /tmp/build-hello-cargo.sh << '"'"'BUILDEOF'"'"'
        set -e
        export PATH=/nix/system/profile/bin:/bin:/usr/bin
        export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
        export HOME="$TMPDIR"
        export CARGO_HOME="$TMPDIR/cargo-home"
        SRCDIR="$TMPDIR/hello-src"
        mkdir -p "$SRCDIR/src" "$CARGO_HOME" "$out/bin"
        cat > "$SRCDIR/Cargo.toml" << TOML
        [package]
        name = "hello"
        version = "0.1.0"
        edition = "2021"
  TOML
        cat > "$SRCDIR/src/main.rs" << RUST
        fn main() {
            println!("Hello from Nix-built Rust on Redox!");
        }
  RUST
        mkdir -p "$SRCDIR/.cargo"
        cat > "$SRCDIR/.cargo/config.toml" << CFG
        [build]
        jobs = 2
        target = "x86_64-unknown-redox"
        [target.x86_64-unknown-redox]
        linker = "/nix/system/profile/bin/cc"
  CFG
        cd "$SRCDIR"
        MAX_TIME=120
        for attempt in 1 2 3; do
          cargo build --offline -j2 &
          PID=$!
          SECONDS=0
          while kill -0 $PID 2>/dev/null; do
            if [ $SECONDS -ge $MAX_TIME ]; then
              echo "[builder] cargo timeout attempt $attempt" >&2
              kill $PID 2>/dev/null; wait $PID 2>/dev/null
              kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
              rm -f "$CARGO_HOME/.package-cache"* 2>/dev/null
              continue 2
            fi
            cat /scheme/sys/uname > /dev/null 2>/dev/null || true
          done
          cat /scheme/sys/uname > /dev/null 2>/dev/null || true
          wait $PID
          CARGO_EXIT=$?
          if [ $CARGO_EXIT -eq 0 ]; then
            break
          else
            echo "[builder] cargo failed (exit=$CARGO_EXIT) attempt $attempt" >&2
            if [ $attempt -eq 3 ]; then
              exit $CARGO_EXIT
            fi
          fi
        done
        cp target/x86_64-unknown-redox/debug/hello "$out/bin/hello"
  BUILDEOF

                          cat > /tmp/hello-cargo.nix << '"'"'HELLONIX'"'"'
        derivation {
          name = "hello-cargo";
          builder = "/nix/system/profile/bin/bash";
          args = ["/tmp/build-hello-cargo.sh"];
          system = "x86_64-unknown-redox";
        }
  HELLONIX

                          rm -f /tmp/.cc-wrapper-raw-args /tmp/.cc-wrapper-stderr /tmp/.cc-wrapper-shared-cmd /tmp/.cc-wrapper-last-err 2>/dev/null

                          OUTPUT=$(/bin/snix build --file /tmp/hello-cargo.nix 2>/tmp/snix-build-cargo-err)
                          EXIT=$?
                          if [ $EXIT -eq 0 ] && [ -x "$OUTPUT/bin/hello" ]; then
                            RUN=$("$OUTPUT/bin/hello" 2>&1)
                            if [ "$RUN" = "Hello from Nix-built Rust on Redox!" ]; then
                              echo "FUNC_TEST:snix-build-cargo:PASS"
                            else
                              echo "FUNC_TEST:snix-build-cargo:FAIL:output=$RUN"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-cargo:FAIL:exit=$EXIT"
                            echo "=== stderr ==="
                            cat /tmp/snix-build-cargo-err 2>/dev/null
                            echo "=== cc-wrapper-stderr ==="
                            cat /tmp/.cc-wrapper-stderr 2>/dev/null
                            echo "=== end ==="
                          fi
                        '

                        # ── Test: cargo build with build.rs + dependency ───
                        # A more complex Nix derivation that runs cargo build for a
                        # workspace crate with a build.rs and a path dependency.
                        # This exercises the sandbox proxy under deeper process trees.
                        echo ""
                        echo "--- snix-build-cargo-complex: cargo with build.rs + dep ---"
                        /nix/system/profile/bin/bash -c '
                          cat > /tmp/build-cargo-complex.sh << '"'"'BUILDEOF'"'"'
        set -e
        export PATH=/nix/system/profile/bin:/bin:/usr/bin
        export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
        export HOME="$TMPDIR"
        export CARGO_HOME="$TMPDIR/cargo-home"
        SRCDIR="$TMPDIR/complex-src"
        mkdir -p "$SRCDIR/src" "$SRCDIR/mylib/src" "$CARGO_HOME" "$out/bin"

        # Path dependency: mylib
        cat > "$SRCDIR/mylib/Cargo.toml" << TOML
        [package]
        name = "mylib"
        version = "0.1.0"
        edition = "2021"
  TOML
        cat > "$SRCDIR/mylib/src/lib.rs" << RUST
        pub fn greeting() -> &'"'"'static str {
            "Hello from complex sandbox build!"
        }
  RUST

        # Main crate with build.rs + dependency on mylib
        cat > "$SRCDIR/Cargo.toml" << TOML
        [package]
        name = "complex-hello"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        mylib = { path = "mylib" }
  TOML
        cat > "$SRCDIR/src/main.rs" << RUST
        fn main() {
            println!("{}", mylib::greeting());
            println!("BUILD_TIME={}", env!("BUILD_TIMESTAMP"));
        }
  RUST
        cat > "$SRCDIR/build.rs" << RUST
        fn main() {
            println!("cargo:rustc-env=BUILD_TIMESTAMP=sandbox-verified");
        }
  RUST

        mkdir -p "$SRCDIR/.cargo"
        cat > "$SRCDIR/.cargo/config.toml" << CFG
        [build]
        jobs = 2
        target = "x86_64-unknown-redox"
        [target.x86_64-unknown-redox]
        linker = "/nix/system/profile/bin/cc"
  CFG
        cd "$SRCDIR"
        MAX_TIME=180
        cargo build --offline -j2 &
        PID=$!
        SECONDS=0
        while kill -0 $PID 2>/dev/null; do
          if [ $SECONDS -ge $MAX_TIME ]; then
            echo "[builder] cargo timeout" >&2
            kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
            exit 1
          fi
          cat /scheme/sys/uname > /dev/null 2>/dev/null || true
        done
        cat /scheme/sys/uname > /dev/null 2>/dev/null || true
        wait $PID
        CARGO_EXIT=$?
        if [ $CARGO_EXIT -ne 0 ]; then
          exit $CARGO_EXIT
        fi
        cp target/x86_64-unknown-redox/debug/complex-hello "$out/bin/complex-hello"
  BUILDEOF

                          cat > /tmp/cargo-complex.nix << '"'"'COMPLEXNIX'"'"'
        derivation {
          name = "cargo-complex";
          builder = "/nix/system/profile/bin/bash";
          args = ["/tmp/build-cargo-complex.sh"];
          system = "x86_64-unknown-redox";
        }
  COMPLEXNIX

                          OUTPUT=$(/bin/snix build --file /tmp/cargo-complex.nix 2>/tmp/snix-build-cargo-complex-err)
                          EXIT=$?
                          if [ $EXIT -eq 0 ] && [ -x "$OUTPUT/bin/complex-hello" ]; then
                            RUN=$("$OUTPUT/bin/complex-hello" 2>&1)
                            if echo "$RUN" | grep -q "Hello from complex sandbox build" && echo "$RUN" | grep -q "BUILD_TIME=sandbox-verified"; then
                              echo "FUNC_TEST:snix-build-cargo-complex:PASS"
                            else
                              echo "FUNC_TEST:snix-build-cargo-complex:FAIL:output=$RUN"
                            fi
                          else
                            echo "FUNC_TEST:snix-build-cargo-complex:FAIL:exit=$EXIT"
                            echo "=== stderr ==="
                            head -c 2000 /tmp/snix-build-cargo-complex-err 2>/dev/null
                            echo "=== end ==="
                          fi
                        '

                        echo ""
                        echo "FUNC_TESTS_COMPLETE"
  '';

  # Build from the self-hosting profile
  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };
in
selfHosting
// {
  # Larger disk for build artifacts
  "/boot" = (selfHosting."/boot" or { }) // {
    diskSizeMB = 4096;
  };

  # Enable sandbox — the per-path proxy is what we are testing
  "/snix" = {
    sandbox = true;
  };

  # Disable interactive login — just run the test script
  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = testScript;
  };

  # No userutils — run the test script directly (not via login loop)
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
