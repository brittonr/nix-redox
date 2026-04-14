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

    # ── snix-build-simple: baseline (no cargo) ──
    /nix/system/profile/bin/bash -c '
      /bin/snix build --expr "derivation { name = \"simple\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo hello > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" >/tmp/simple-out 2>/tmp/simple-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/simple-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        echo "FUNC_TEST:snix-simple:PASS"
      else
        echo "FUNC_TEST:snix-simple:FAIL:exit=$EXIT"
        cat /tmp/simple-err 2>/dev/null | head -20 >&2
      fi
    '

    # ── snix-build-cargo: hello world cargo in sandbox ──
    echo "--- snix-build-cargo ---"
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
cargo build --offline -j2 2>&1
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

      echo "[snix-build-cargo] starting..." >&2
      /bin/snix build --file /tmp/hello-cargo.nix >/tmp/snix-build-cargo-out 2>/tmp/snix-build-cargo-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/snix-build-cargo-out 2>/dev/null)
      echo "[snix-build-cargo] exit=$EXIT output=$OUTPUT" >&2
      if [ $EXIT -eq 0 ] && [ -x "$OUTPUT/bin/hello" ]; then
        RUN=$("$OUTPUT/bin/hello" 2>&1)
        if [ "$RUN" = "Hello from Nix-built Rust on Redox!" ]; then
          echo "FUNC_TEST:snix-build-cargo:PASS"
        else
          echo "FUNC_TEST:snix-build-cargo:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:snix-build-cargo:FAIL:exit=$EXIT"
        echo "=== stderr ===" >&2
        cat /tmp/snix-build-cargo-err 2>/dev/null >&2
        echo "=== end ===" >&2
      fi
    '

    # ── flake-build ──
    echo "--- flake-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      /bin/snix build "/usr/src/test-flake#hello" >/tmp/flake-build-out 2>/tmp/flake-build-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/flake-build-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/hello" ]; then
        RUN=$("$OUTPUT/bin/hello" 2>&1)
        if [ "$RUN" = "Hello from flake!" ]; then
          echo "FUNC_TEST:flake-build:PASS"
        else
          echo "FUNC_TEST:flake-build:FAIL:wrong output: $RUN"
        fi
      else
        echo "FUNC_TEST:flake-build:FAIL:exit=$EXIT output=$OUTPUT"
        cat /tmp/flake-build-err 2>/dev/null | head -20 >&2
      fi
    '

    # ── file-build probes ──
    echo "--- file-build-tmp-probe ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/file-build-probe.nix << '"'"'TMPNIX'"'"'
derivation {
  name = "file-probe-tmp";
  builder = "/nix/system/profile/bin/bash";
  args = [ "/usr/src/test-flake/build-file-probe.sh" ];
  system = "x86_64-unknown-redox";
}
TMPNIX
      /bin/snix build --file /tmp/file-build-probe.nix >/tmp/file-build-probe-out 2>/tmp/file-build-probe-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/file-build-probe-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ] && grep -q "FILE_PROBE_OK" "$OUTPUT"; then
        echo "FUNC_TEST:file-build-tmp-probe:PASS"
      else
        echo "FUNC_TEST:file-build-tmp-probe:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== file-build-tmp stderr ===" >&2
        cat /tmp/file-build-probe-err 2>/dev/null >&2
        echo "=== file-build-tmp stdout ===" >&2
        cat /tmp/file-build-probe-out 2>/dev/null | head -40 >&2
      fi
    '

    echo "--- file-build-usrsrc-probe ---"
    /nix/system/profile/bin/bash -c '
      /bin/snix build --file /usr/src/test-flake/file-build.nix >/tmp/file-build-usrsrc-out 2>/tmp/file-build-usrsrc-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/file-build-usrsrc-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ] && grep -q "FILE_PROBE_OK" "$OUTPUT"; then
        echo "FUNC_TEST:file-build-usrsrc-probe:PASS"
      else
        echo "FUNC_TEST:file-build-usrsrc-probe:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== file-build-usrsrc stderr ===" >&2
        cat /tmp/file-build-usrsrc-err 2>/dev/null >&2
        echo "=== file-build-usrsrc stdout ===" >&2
        cat /tmp/file-build-usrsrc-out 2>/dev/null | head -40 >&2
      fi
    '

    echo "--- direct-bash-multiarg-probe ---"
    /nix/system/profile/bin/bash -c '
      rm -rf /tmp/direct-file-probe-out /tmp/direct-file-probe-tmp
      mkdir -p /tmp/direct-file-probe-tmp
      out=/tmp/direct-file-probe-out TMPDIR=/tmp/direct-file-probe-tmp /nix/system/profile/bin/bash --noprofile --norc /usr/src/test-flake/build-file-probe.sh >/tmp/direct-bash-probe-out 2>/tmp/direct-bash-probe-err
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f /tmp/direct-file-probe-out ] && grep -q "FILE_PROBE_OK" /tmp/direct-file-probe-out; then
        echo "FUNC_TEST:direct-bash-multiarg-probe:PASS"
      else
        echo "FUNC_TEST:direct-bash-multiarg-probe:FAIL:exit=$EXIT"
        echo "=== direct bash stderr ===" >&2
        cat /tmp/direct-bash-probe-err 2>/dev/null >&2
        echo "=== direct bash stdout ===" >&2
        cat /tmp/direct-bash-probe-out 2>/dev/null | head -40 >&2
      fi
    '

    echo "--- file-build-multiarg-tmp-probe ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/file-build-multiarg-probe.nix << '"'"'TMPNIX'"'"'
derivation {
  name = "file-probe-multiarg-tmp";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "/usr/src/test-flake/build-file-probe.sh" ];
  system = "x86_64-unknown-redox";
}
TMPNIX
      rm -f /tmp/snix-debug.log
      /bin/snix build --file /tmp/file-build-multiarg-probe.nix >/tmp/file-build-multiarg-probe-out 2>/tmp/file-build-multiarg-probe-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/file-build-multiarg-probe-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ] && grep -q "FILE_PROBE_OK" "$OUTPUT"; then
        echo "FUNC_TEST:file-build-multiarg-tmp-probe:PASS"
      else
        echo "FUNC_TEST:file-build-multiarg-tmp-probe:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== file-build-multiarg-tmp stderr ===" >&2
        cat /tmp/file-build-multiarg-probe-err 2>/dev/null >&2
        echo "=== file-build-multiarg-tmp stdout ===" >&2
        cat /tmp/file-build-multiarg-probe-out 2>/dev/null | head -40 >&2
        echo "=== file-build-multiarg-tmp snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
      fi
    '

    echo "--- file-build-multiarg-usrsrc-probe ---"
    /nix/system/profile/bin/bash -c '
      rm -f /tmp/snix-debug.log
      /bin/snix build --file /usr/src/test-flake/file-build-multiarg.nix >/tmp/file-build-multiarg-usrsrc-out 2>/tmp/file-build-multiarg-usrsrc-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/file-build-multiarg-usrsrc-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ] && grep -q "FILE_PROBE_OK" "$OUTPUT"; then
        echo "FUNC_TEST:file-build-multiarg-usrsrc-probe:PASS"
      else
        echo "FUNC_TEST:file-build-multiarg-usrsrc-probe:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== file-build-multiarg-usrsrc stderr ===" >&2
        cat /tmp/file-build-multiarg-usrsrc-err 2>/dev/null >&2
        echo "=== file-build-multiarg-usrsrc stdout ===" >&2
        cat /tmp/file-build-multiarg-usrsrc-out 2>/dev/null | head -40 >&2
        echo "=== file-build-multiarg-usrsrc snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
      fi
    '

    echo "--- direct-cc-dep-script ---"
    /nix/system/profile/bin/bash -c '
      rm -rf /tmp/direct-cc-dep-out /tmp/direct-cc-dep-tmp
      mkdir -p /tmp/direct-cc-dep-tmp
      out=/tmp/direct-cc-dep-out TMPDIR=/tmp/direct-cc-dep-tmp /nix/system/profile/bin/bash --noprofile --norc /usr/src/cc-dep-test/build-cc-dep.sh >/tmp/direct-cc-dep-stdout 2>/tmp/direct-cc-dep-stderr
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -x /tmp/direct-cc-dep-out/bin/cc-dep-test ]; then
        RUN=$(/tmp/direct-cc-dep-out/bin/cc-dep-test 2>&1)
        if echo "$RUN" | grep -q "CC_DEP_OK"; then
          echo "FUNC_TEST:direct-cc-dep-script:PASS"
        else
          echo "FUNC_TEST:direct-cc-dep-script:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:direct-cc-dep-script:FAIL:exit=$EXIT"
        echo "=== direct cc-dep stderr ===" >&2
        cat /tmp/direct-cc-dep-stderr 2>/dev/null >&2
        echo "=== direct cc-dep stdout ===" >&2
        cat /tmp/direct-cc-dep-stdout 2>/dev/null | head -60 >&2
      fi
    '

    echo "--- direct-workspace-script ---"
    /nix/system/profile/bin/bash -c '
      rm -rf /tmp/direct-workspace-out /tmp/direct-workspace-tmp
      mkdir -p /tmp/direct-workspace-tmp
      out=/tmp/direct-workspace-out TMPDIR=/tmp/direct-workspace-tmp /nix/system/profile/bin/bash --noprofile --norc /usr/src/workspace-test/build-workspace.sh >/tmp/direct-workspace-stdout 2>/tmp/direct-workspace-stderr
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -x /tmp/direct-workspace-out/bin/mybin ]; then
        RUN=$(/tmp/direct-workspace-out/bin/mybin 2>&1)
        if echo "$RUN" | grep -q "WORKSPACE_OK"; then
          echo "FUNC_TEST:direct-workspace-script:PASS"
        else
          echo "FUNC_TEST:direct-workspace-script:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:direct-workspace-script:FAIL:exit=$EXIT"
        echo "=== direct workspace stderr ===" >&2
        cat /tmp/direct-workspace-stderr 2>/dev/null >&2
        echo "=== direct workspace stdout ===" >&2
        cat /tmp/direct-workspace-stdout 2>/dev/null | head -60 >&2
      fi
    '

    echo "--- cc-dep-expr-serial ---"
    /nix/system/profile/bin/bash -c '
      rm -f /tmp/snix-debug.log
      /bin/snix build --expr "derivation { name = \"cc-dep-expr-serial\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"--noprofile\" \"--norc\" \"/usr/src/cc-dep-test/build-cc-dep.sh\"]; system = \"x86_64-unknown-redox\"; }"
      EXIT=$?
      echo "FUNC_TEST:cc-dep-expr-serial:exit=$EXIT"
      echo "=== cc-dep serial snix-debug ==="
      cat /tmp/snix-debug.log 2>/dev/null
    '

    echo "--- cc-dep-expr-probe ---"
    /nix/system/profile/bin/bash -c '
      rm -f /tmp/snix-debug.log
      /bin/snix build --expr "derivation { name = \"cc-dep-expr-probe\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"--noprofile\" \"--norc\" \"/usr/src/cc-dep-test/build-cc-dep.sh\"]; system = \"x86_64-unknown-redox\"; }" >/tmp/cc-dep-expr-out 2>/tmp/cc-dep-expr-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/cc-dep-expr-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/cc-dep-test" ]; then
        RUN=$("$OUTPUT/bin/cc-dep-test" 2>&1)
        if echo "$RUN" | grep -q "CC_DEP_OK"; then
          echo "FUNC_TEST:cc-dep-expr-probe:PASS"
        else
          echo "FUNC_TEST:cc-dep-expr-probe:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:cc-dep-expr-probe:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== cc-dep expr stderr ===" >&2
        cat /tmp/cc-dep-expr-err 2>/dev/null >&2
        echo "=== cc-dep expr stdout ===" >&2
        cat /tmp/cc-dep-expr-out 2>/dev/null | head -40 >&2
        echo "=== cc-dep expr snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
      fi
    '

    echo "--- workspace-expr-probe ---"
    /nix/system/profile/bin/bash -c '
      rm -f /tmp/snix-debug.log
      /bin/snix build --expr "derivation { name = \"workspace-expr-probe\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"--noprofile\" \"--norc\" \"/usr/src/workspace-test/build-workspace.sh\"]; system = \"x86_64-unknown-redox\"; }" >/tmp/workspace-expr-out 2>/tmp/workspace-expr-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/workspace-expr-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/mybin" ]; then
        RUN=$("$OUTPUT/bin/mybin" 2>&1)
        if echo "$RUN" | grep -q "WORKSPACE_OK"; then
          echo "FUNC_TEST:workspace-expr-probe:PASS"
        else
          echo "FUNC_TEST:workspace-expr-probe:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:workspace-expr-probe:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== workspace expr stderr ===" >&2
        cat /tmp/workspace-expr-err 2>/dev/null >&2
        echo "=== workspace expr stdout ===" >&2
        cat /tmp/workspace-expr-out 2>/dev/null | head -40 >&2
        echo "=== workspace expr snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
      fi
    '

    echo "--- cc-dep-build-nix-copy ---"
    /nix/system/profile/bin/bash -c '
      cat > /tmp/cc-dep-build-copy.nix << '"'"'CCDEPCOPY'"'"'
derivation {
  name = "cc-dep-test-copy";
  builder = "/nix/system/profile/bin/bash";
  args = [ "--noprofile" "--norc" "/usr/src/cc-dep-test/build-cc-dep.sh" ];
  system = "x86_64-unknown-redox";
}
CCDEPCOPY
      rm -f /tmp/snix-debug.log
      /bin/snix build --file /tmp/cc-dep-build-copy.nix >/tmp/cc-dep-copy-out 2>/tmp/cc-dep-copy-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/cc-dep-copy-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/cc-dep-test" ]; then
        RUN=$("$OUTPUT/bin/cc-dep-test" 2>&1)
        if echo "$RUN" | grep -q "CC_DEP_OK"; then
          echo "FUNC_TEST:cc-dep-build-nix-copy:PASS"
        else
          echo "FUNC_TEST:cc-dep-build-nix-copy:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:cc-dep-build-nix-copy:FAIL:exit=$EXIT output=$OUTPUT"
        echo "=== cc-dep-copy stderr ===" >&2
        cat /tmp/cc-dep-copy-err 2>/dev/null >&2
        echo "=== cc-dep-copy stdout ===" >&2
        cat /tmp/cc-dep-copy-out 2>/dev/null | head -40 >&2
        echo "=== cc-dep-copy snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
      fi
    '

    # ── cc-dep-build ──
    echo "--- cc-dep-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      rm -f /tmp/snix-debug.log
      /bin/snix build --file /usr/src/cc-dep-test/build.nix >/tmp/cc-dep-out 2>/tmp/cc-dep-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/cc-dep-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/cc-dep-test" ]; then
        RUN=$("$OUTPUT/bin/cc-dep-test" 2>&1)
        if echo "$RUN" | grep -q "CC_DEP_OK"; then
          echo "FUNC_TEST:cc-dep-build:PASS"
        else
          echo "FUNC_TEST:cc-dep-build:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:cc-dep-build:FAIL:exit=$EXIT"
        echo "=== cc-dep stderr ===" >&2
        cat /tmp/cc-dep-err 2>/dev/null >&2
        echo "=== cc-dep stdout ===" >&2
        cat /tmp/cc-dep-out 2>/dev/null | head -40 >&2
        echo "=== cc-dep snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
        if [ -n "$OUTPUT" ]; then
          echo "=== cc-dep output tree ===" >&2
          ls -ld "$OUTPUT" "$OUTPUT/bin" "$OUTPUT/bin/cc-dep-test" >/tmp/cc-dep-tree 2>&1
          ls -l "$OUTPUT/bin" >>/tmp/cc-dep-tree 2>&1
          cat /tmp/cc-dep-tree 2>/dev/null >&2
        fi
      fi
    '

    # ── workspace-build ──
    echo "--- workspace-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      rm -f /tmp/snix-debug.log
      /bin/snix build --file /usr/src/workspace-test/build.nix >/tmp/workspace-out 2>/tmp/workspace-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/workspace-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/mybin" ]; then
        RUN=$("$OUTPUT/bin/mybin" 2>&1)
        if echo "$RUN" | grep -q "WORKSPACE_OK"; then
          echo "FUNC_TEST:workspace-build:PASS"
        else
          echo "FUNC_TEST:workspace-build:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:workspace-build:FAIL:exit=$EXIT"
        echo "=== workspace stderr ===" >&2
        cat /tmp/workspace-err 2>/dev/null >&2
        echo "=== workspace stdout ===" >&2
        cat /tmp/workspace-out 2>/dev/null | head -40 >&2
        echo "=== workspace snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
      fi
    '

    echo "--- direct-rg-script ---"
    /nix/system/profile/bin/bash -c '
      rm -rf /tmp/direct-rg-out /tmp/direct-rg-tmp
      mkdir -p /tmp/direct-rg-tmp
      out=/tmp/direct-rg-out TMPDIR=/tmp/direct-rg-tmp /nix/system/profile/bin/bash --noprofile --norc /usr/src/ripgrep/build-ripgrep.sh >/tmp/direct-rg-stdout 2>/tmp/direct-rg-stderr
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -x /tmp/direct-rg-out/bin/rg ]; then
        VER=$(/tmp/direct-rg-out/bin/rg --version 2>&1 | head -1)
        if echo "$VER" | grep -q "ripgrep"; then
          echo "FUNC_TEST:direct-rg-script:PASS"
        else
          echo "FUNC_TEST:direct-rg-script:FAIL:version=$VER"
        fi
      else
        echo "FUNC_TEST:direct-rg-script:FAIL:exit=$EXIT"
        echo "=== direct rg stderr ===" >&2
        cat /tmp/direct-rg-stderr 2>/dev/null >&2
        echo "=== direct rg stdout ===" >&2
        cat /tmp/direct-rg-stdout 2>/dev/null | head -80 >&2
      fi
    '

    # ── rg-build ──
    echo "--- rg-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      rm -f /tmp/snix-debug.log
      /bin/snix build --file /usr/src/ripgrep/build.nix >/tmp/rg-build-out 2>/tmp/rg-build-err
      EXIT=$?
      OUTPUT=$(head -1 /tmp/rg-build-out 2>/dev/null)
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/rg" ]; then
        VER=$("$OUTPUT/bin/rg" --version 2>&1 | head -1)
        if echo "$VER" | grep -q "ripgrep"; then
          echo "FUNC_TEST:rg-build:PASS"
        else
          echo "FUNC_TEST:rg-build:FAIL:version=$VER"
        fi
      else
        echo "FUNC_TEST:rg-build:FAIL:exit=$EXIT"
        echo "=== rg stderr ===" >&2
        cat /tmp/rg-build-err 2>/dev/null >&2
        echo "=== rg stdout ===" >&2
        cat /tmp/rg-build-out 2>/dev/null | head -40 >&2
        echo "=== rg snix-debug ===" >&2
        cat /tmp/snix-debug.log 2>/dev/null >&2
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
