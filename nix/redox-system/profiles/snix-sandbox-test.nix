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
      OUTPUT=$(/bin/snix build --expr "derivation { name = \"simple\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo hello > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" 2>/tmp/simple-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -f "$OUTPUT" ]; then
        echo "FUNC_TEST:snix-simple:PASS"
      else
        echo "FUNC_TEST:snix-simple:FAIL:exit=$EXIT"
        cat /tmp/simple-err 2>/dev/null | head -5
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
      OUTPUT=$(/bin/snix build --file /tmp/hello-cargo.nix 2>/tmp/snix-build-cargo-err)
      EXIT=$?
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
      OUTPUT=$(/bin/snix build "/usr/src/test-flake#hello" 2>/tmp/flake-build-err)
      EXIT=$?
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

    # ── cc-dep-build ──
    echo "--- cc-dep-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      OUTPUT=$(/bin/snix build --file /usr/src/cc-dep-test/build.nix 2>/tmp/cc-dep-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/cc-dep-test" ]; then
        RUN=$("$OUTPUT/bin/cc-dep-test" 2>&1)
        if echo "$RUN" | grep -q "CC_DEP_OK"; then
          echo "FUNC_TEST:cc-dep-build:PASS"
        else
          echo "FUNC_TEST:cc-dep-build:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:cc-dep-build:FAIL:exit=$EXIT"
        cat /tmp/cc-dep-err 2>/dev/null | head -20 >&2
      fi
    '

    # ── workspace-build ──
    echo "--- workspace-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      OUTPUT=$(/bin/snix build --file /usr/src/workspace-test/build.nix 2>/tmp/workspace-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/mybin" ]; then
        RUN=$("$OUTPUT/bin/mybin" 2>&1)
        if echo "$RUN" | grep -q "WORKSPACE_OK"; then
          echo "FUNC_TEST:workspace-build:PASS"
        else
          echo "FUNC_TEST:workspace-build:FAIL:output=$RUN"
        fi
      else
        echo "FUNC_TEST:workspace-build:FAIL:exit=$EXIT"
        cat /tmp/workspace-err 2>/dev/null | head -20 >&2
      fi
    '

    # ── rg-build ──
    echo "--- rg-build ---"
    /nix/system/profile/bin/bash -c '
      mkdir -p /nix/store /nix/var/snix/pathinfo
      OUTPUT=$(/bin/snix build --file /usr/src/ripgrep/build.nix 2>/tmp/rg-build-err)
      EXIT=$?
      if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/rg" ]; then
        VER=$("$OUTPUT/bin/rg" --version 2>&1 | head -1)
        if echo "$VER" | grep -q "ripgrep"; then
          echo "FUNC_TEST:rg-build:PASS"
        else
          echo "FUNC_TEST:rg-build:FAIL:version=$VER"
        fi
      else
        echo "FUNC_TEST:rg-build:FAIL:exit=$EXIT"
        cat /tmp/rg-build-err 2>/dev/null | head -20 >&2
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
