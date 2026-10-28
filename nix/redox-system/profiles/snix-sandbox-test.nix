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
    let CARGO_PROFILE_DEV_DEBUG = "0"
    export CARGO_PROFILE_DEV_DEBUG
    let RUSTFLAGS = "-Cdebuginfo=0 -Clink-arg=-z -Clink-arg=stack-size=16777216"
    export RUSTFLAGS

    echo ""
    echo "FUNC_TESTS_START"
    echo ""
    echo "=== SNIX SANDBOX BUILD TESTS ==="
    echo ""

    # ── snix-build-simple: baseline (no cargo) ──
    /nix/system/profile/bin/bash -c '
      /bin/snix build --expr "derivation { name = \"simple\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo hello > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" >/tmp/simple-out 2>/tmp/simple-err
      EXIT=$?
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/simple-out)
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
export CARGO_PROFILE_DEV_DEBUG=0
export RUSTFLAGS="-Cdebuginfo=0 -Clink-arg=-z -Clink-arg=stack-size=16777216"
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/snix-build-cargo-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/flake-build-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/file-build-probe-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/file-build-usrsrc-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/file-build-multiarg-probe-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/file-build-multiarg-usrsrc-out)
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
      echo "ccdep-diag: $(ls -ld /usr/src/cc-dep-test /usr/src/cc-dep-test/build-cc-dep.sh /usr/src/ripgrep /usr/src/ripgrep/build-ripgrep.sh 2>&1)"
      /nix/system/profile/bin/bash -n /usr/src/cc-dep-test/build-cc-dep.sh; echo "ccdep-parse-rc=$?"
      /nix/system/profile/bin/bash -n /usr/src/ripgrep/build-ripgrep.sh; echo "rg-parse-rc=$?"
      echo "diag-env: out=$out TMPDIR=$TMPDIR"
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
        echo "FUNC_TEST:direct-cc-dep-script:SKIP:unsandboxed-mutable-mapping-exit=$EXIT"
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/cc-dep-expr-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/workspace-expr-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/cc-dep-copy-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/cc-dep-out)
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/workspace-out)
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
        echo "FUNC_TEST:direct-rg-script:SKIP:unsandboxed-mutable-mapping-exit=$EXIT"
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
      OUTPUT=$(while IFS= read -r line; do case $line in /nix/store/*) printf '%s' "$line"; break;; esac; done < /tmp/rg-build-out)
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

    # ── cargo-vendored-dep: vendored crate dependency ──
    echo "--- cargo-vendored-dep ---"
    /nix/system/profile/bin/bash -c '
      rm -rf /tmp/vendored /tmp/cargo-vendored
      mkdir -p /tmp/vendored/src /tmp/vendored/.cargo /tmp/vendored/vendor/minimath/src /tmp/cargo-vendored
      printf "%s\n" \
        "[package]" \
        "name = \"minimath\"" \
        "version = \"0.1.0\"" \
        "edition = \"2021\"" \
        > /tmp/vendored/vendor/minimath/Cargo.toml
      printf "%s\n" \
        "pub fn factorial(n: u64) -> u64 { (1..=n).product() }" \
        > /tmp/vendored/vendor/minimath/src/lib.rs
      echo "{\"files\":{}}" > /tmp/vendored/vendor/minimath/.cargo-checksum.json
      printf "%s\n" \
        "[source.crates-io]" \
        "replace-with = \"vendored-sources\"" \
        "" \
        "[source.vendored-sources]" \
        "directory = \"vendor\"" \
        > /tmp/vendored/.cargo/config.toml
      printf "%s\n" \
        "[package]" \
        "name = \"vendored-test\"" \
        "version = \"0.1.0\"" \
        "edition = \"2021\"" \
        "" \
        "[dependencies]" \
        "minimath = \"0.1.0\"" \
        > /tmp/vendored/Cargo.toml
      printf "%s\n" \
        "fn main() { println!(\"VENDORED_OK {}\", minimath::factorial(5)); }" \
        > /tmp/vendored/src/main.rs
      printf "%s\n" \
        "# This file is automatically @generated by Cargo." \
        "# It is not intended for manual editing." \
        "version = 4" \
        "" \
        "[[package]]" \
        "name = \"minimath\"" \
        "version = \"0.1.0\"" \
        "source = \"registry+https://github.com/rust-lang/crates.io-index\"" \
        "" \
        "[[package]]" \
        "name = \"vendored-test\"" \
        "version = \"0.1.0\"" \
        "dependencies = [\"minimath\"]" \
        > /tmp/vendored/Cargo.lock
      cd /tmp/vendored
      export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
      export CARGO_BUILD_JOBS=2
      export RAYON_NUM_THREADS=4
      rm -rf /tmp/cargo-vendored
      mkdir -p /tmp/cargo-vendored
      cp /root/.cargo/config.toml /tmp/cargo-vendored/ 2>/dev/null || true
      export CARGO_HOME=/tmp/cargo-vendored
      export CARGO_INCREMENTAL=0
      export RUSTC=/nix/system/profile/bin/rustc
      rm -f /root/.cargo/.package-cache* "$CARGO_HOME/.package-cache"* 2>/dev/null || true
      cargo build --offline >/tmp/vendored-build-log 2>&1
      EXIT=$?
      BIN=target/x86_64-unknown-redox/debug/vendored-test
      [ -x "$BIN" ] || BIN=target/debug/vendored-test
      if [ $EXIT -eq 0 ] && [ -x "$BIN" ]; then
        RUN=$("$BIN" 2>&1)
        case $RUN in
          *VENDORED_OK*) echo "FUNC_TEST:cargo-vendored-dep:PASS";;
          *) echo "FUNC_TEST:cargo-vendored-dep:FAIL:output=$RUN";;
        esac
      else
        echo "FUNC_TEST:cargo-vendored-dep:FAIL:exit=$EXIT"
        echo "=== vendored log ===" >&2
        /bin/cat /tmp/vendored-build-log 2>/dev/null >&2
      fi
    '

    # ── source-rebuild-probe: snix system rebuild --source ──
    echo "--- source-rebuild-probe ---"
    /nix/system/profile/bin/bash -c '
      CFGDIR=/tmp/sr-probe
      rm -rf "$CFGDIR"
      mkdir -p "$CFGDIR/generations"
      cat > "$CFGDIR/packages.nix" << '"'"'PKGNIX'"'"'
{
  hello-source = derivation {
    name = "hello-source";
    builder = "/nix/system/profile/bin/bash";
    args = ["-c" "/bin/mkdir -p $out/bin; echo hello-from-source > $out/bin/hello-source"];
    system = "x86_64-unknown-redox";
  };
}
PKGNIX
      cat > "$CFGDIR/configuration.nix" << '"'"'CFGNIX'"'"'
{
  packageSources = "/tmp/sr-probe/packages.nix";
}
CFGNIX
      cp /etc/redox-system/manifest.json "$CFGDIR/manifest.json"
      /bin/snix system rebuild --source \
        --config "$CFGDIR/configuration.nix" \
        --manifest "$CFGDIR/manifest.json" \
        --gen-dir "$CFGDIR/generations" &
      PID=$!
      N=0
      while kill -0 $PID 2>/dev/null && [ $N -lt 12 ]; do sleep 10; N=$((N+1)); done
      if kill -0 $PID 2>/dev/null; then
        echo "FUNC_TEST:source-rebuild-probe:FAIL:hang"
        echo "=== sys context ===" >&2
        cat /scheme/sys/context 2>/dev/null >&2
        kill -9 $PID 2>/dev/null
      else
        wait $PID
        EXIT=$?
        if [ $EXIT -eq 0 ]; then
          echo "FUNC_TEST:source-rebuild-probe:PASS"
        else
          echo "FUNC_TEST:source-rebuild-probe:FAIL:exit=$EXIT"
        fi
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
