# Self-Hosting Test Profile
#
# Boots the self-hosting image and tests that cargo build works on-guest.
# Tests: cargo init → cargo build → execute the resulting binary.
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
    echo "  RedoxOS Self-Hosting Test Suite"
    echo "========================================"
    echo ""
    echo "FUNC_TESTS_START"
    echo ""

    # ── Toolchain Presence ──────────────────────────────────
    # Verify the compiler toolchain binaries are accessible

    # Test: rustc is in PATH
    if exists -f /nix/system/profile/bin/rustc
      echo "FUNC_TEST:rustc-exists:PASS"
    else
      echo "FUNC_TEST:rustc-exists:FAIL:rustc not found in profile"
    end

    # Test: cargo is in PATH
    if exists -f /nix/system/profile/bin/cargo
      echo "FUNC_TEST:cargo-exists:PASS"
    else
      echo "FUNC_TEST:cargo-exists:FAIL:cargo not found in profile"
    end

    # Test: cc wrapper is in PATH
    if exists -f /nix/system/profile/bin/cc
      echo "FUNC_TEST:cc-exists:PASS"
    else
      echo "FUNC_TEST:cc-exists:FAIL:cc wrapper not found in profile"
    end

    # Test: lld (linker) is in PATH
    if exists -f /nix/system/profile/bin/lld
      echo "FUNC_TEST:lld-exists:PASS"
    else
      echo "FUNC_TEST:lld-exists:FAIL:lld not found in profile"
    end

    # Test: clang is in PATH
    if exists -f /nix/system/profile/bin/clang
      echo "FUNC_TEST:clang-exists:PASS"
    else
      echo "FUNC_TEST:clang-exists:FAIL:clang not found in profile"
    end

    # ── Sysroot ─────────────────────────────────────────────
    # Verify the sysroot is properly set up

    # Test: sysroot symlink exists
    if exists -d /usr/lib/redox-sysroot
      echo "FUNC_TEST:sysroot-exists:PASS"
    else
      echo "FUNC_TEST:sysroot-exists:FAIL:/usr/lib/redox-sysroot not found"
    end

    # Test: libc.a exists in sysroot
    if exists -f /usr/lib/redox-sysroot/lib/libc.a
      echo "FUNC_TEST:sysroot-libc:PASS"
    else
      echo "FUNC_TEST:sysroot-libc:FAIL:libc.a not found in sysroot"
    end

    # Test: relibc headers exist
    if exists -f /usr/lib/redox-sysroot/include/stdio.h
      echo "FUNC_TEST:sysroot-headers:PASS"
    else
      echo "FUNC_TEST:sysroot-headers:FAIL:stdio.h not found in sysroot"
    end

    # Test: CRT files exist
    if exists -f /usr/lib/redox-sysroot/lib/crt0.o
      echo "FUNC_TEST:sysroot-crt:PASS"
    else
      echo "FUNC_TEST:sysroot-crt:FAIL:crt0.o not found in sysroot"
    end

    # ── Rustc Dynamic Libraries ─────────────────────────────
    # Test: LD_LIBRARY_PATH includes rustc libs

    # Test: librustc_driver.so accessible (check all lib paths)
    let found = false
    for dir in /nix/system/profile/lib /usr/lib/rustc /lib
      for f in @(ls $dir/ 2>/dev/null)
        if matches $f "^librustc_driver"
          let found = true
        end
      end
    end
    if test $found = true
      echo "FUNC_TEST:rustc-driver-so:PASS"
    else
      echo "FUNC_TEST:rustc-driver-so:FAIL:librustc_driver.so not found"
    end

    # ── Cargo Config ────────────────────────────────────────
    # Test: cargo config exists
    if exists -f /root/.cargo/config.toml
      echo "FUNC_TEST:cargo-config:PASS"
    else
      echo "FUNC_TEST:cargo-config:FAIL:/root/.cargo/config.toml not found"
    end

    # ── Cargo Build ─────────────────────────────────────────
    # The main event: compile and run a Rust program on Redox

    # Test: cargo init + cargo build
    cd /tmp
    mkdir -p hello
    cd hello

    # Create a minimal Rust project
    mkdir -p src
    echo 'fn main() { println!("Hello from self-hosted Redox!"); }' > src/main.rs

    # Minimal Cargo.toml (avoid cargo init which might need network)
    echo '[package]' > Cargo.toml
    echo 'name = "hello"' >> Cargo.toml
    echo 'version = "0.1.0"' >> Cargo.toml
    echo 'edition = "2021"' >> Cargo.toml

    # Set up self-hosting environment
    # LD_LIBRARY_PATH: rustc needs librustc_driver.so + all proc-macro .so files
    # Redox's ld_so doesn't support $ORIGIN in RPATH, so we must set this explicitly.
    # CARGO_BUILD_JOBS: Redox relibc lacks sysconf(_SC_NPROCESSORS_ONLN)
    # CARGO_HOME: cargo needs a writable config dir
    let LD_LIBRARY_PATH = "/nix/system/profile/lib:/usr/lib/rustc:/lib"
    export LD_LIBRARY_PATH
    let CARGO_BUILD_JOBS = "1"
    export CARGO_BUILD_JOBS
    let CARGO_HOME = "/tmp/.cargo"
    export CARGO_HOME

    # Test: check if rand scheme is available (needed by rustc for std::random)
    # On Redox, random is provided by the randd daemon via /scheme/rand.
    # List all available schemes to check.
    let rand_found = false
    for f in @(ls /scheme/ ^>/dev/null)
      if test $f = "rand"
        let rand_found = true
      end
    end
    if test $rand_found = true
      echo "FUNC_TEST:rand-scheme:PASS"
    else
      echo "FUNC_TEST:rand-scheme:FAIL:rand scheme not in /scheme/"
      echo "Available schemes:"
      ls /scheme/ ^>/dev/null
    end

    # ── Diagnostics: rand scheme read ───────────────────────
    # Test: can we actually read from /scheme/rand? Use head (uutils)
    head -c 8 /scheme/rand > /tmp/rand-test
    let rand_read_exit = $?
    if test $rand_read_exit = 0
      echo "FUNC_TEST:rand-read:PASS"
    else
      echo "FUNC_TEST:rand-read:FAIL:read /scheme/rand exited $rand_read_exit"
    end

    # Test: rustc -vV directly (not through cargo)
    rustc -vV > /tmp/rustc-vv-out ^>/tmp/rustc-vv-err
    let rustc_vv_exit = $?
    if test $rustc_vv_exit = 0
      echo "FUNC_TEST:rustc-version:PASS"
      cat /tmp/rustc-vv-out
    else
      echo "FUNC_TEST:rustc-version:FAIL:rustc -vV exited $rustc_vv_exit"
      echo "=== rustc stderr ==="
      cat /tmp/rustc-vv-err
      echo "=== end ==="
    end

    # Test: rustc --print cfg (target config query — LLVM option parsing)
    # Let stderr flow to serial so we see any errors / ld_so debug output
    let LD_DEBUG = "1"
    export LD_DEBUG
    rustc --print cfg >/tmp/rustc-print-cfg-out
    let print_cfg_exit = $?
    let LD_DEBUG = "0"
    export LD_DEBUG
    if test $print_cfg_exit = 0
      echo "FUNC_TEST:rustc-print-cfg:PASS"
    else
      echo "FUNC_TEST:rustc-print-cfg:FAIL:rustc --print cfg exited $print_cfg_exit"
      echo "=== rustc print cfg output ==="
      cat /tmp/rustc-print-cfg-out
      echo "=== end ==="
    end

    # Sysroot check
    let sysroot = $(rustc --print sysroot)
    echo "Sysroot: $sysroot"

    # Test: repeated rustc invocations to detect state issues
    echo "=== Sequential rustc tests ==="
    echo "--- Test A: rustc -vV (4th invocation) ---"
    rustc -vV &>/dev/null
    echo "--- Test A: exited $? ---"

    echo "--- Test B: rustc --help ---"
    rustc --help &>/dev/null
    echo "--- Test B: exited $? ---"

    echo "--- Test C: rustc --print target-list ---"
    rustc --print target-list &>/dev/null
    echo "--- Test C: exited $? ---"

    # Now try with a source file
    echo 'fn main() { }' > /tmp/empty.rs
    # Test D: compile empty main → binary (no cargo, no -Z flags)
    echo "--- Test D: rustc /tmp/empty.rs -o /tmp/empty-bin ---"
    rustc /tmp/empty.rs -o /tmp/empty-bin
    let compile_exit = $?
    echo "--- Test D: exited $compile_exit ---"

    # Test E: compile hello with println
    echo 'fn main() { println!("hello from rustc"); }' > /tmp/hello.rs
    echo "--- Test E: rustc /tmp/hello.rs -o /tmp/hello-direct ---"
    rustc /tmp/hello.rs -o /tmp/hello-direct
    let hello_exit = $?
    echo "--- Test E: exited $hello_exit ---"

    # Test F: run the compiled binary
    if test $compile_exit = 0
      if exists -f /tmp/empty-bin
        /tmp/empty-bin
        echo "FUNC_TEST:rustc-compile-direct:PASS"
      else
        echo "FUNC_TEST:rustc-compile-direct:FAIL:binary not found"
      end
    else
      echo "FUNC_TEST:rustc-compile-direct:FAIL:rustc exited $compile_exit"
    end

    # Run cargo build and capture exit code
    # Ion shell: ^> redirects stderr (not 2> like bash)
    # Use &> to capture both stdout and stderr for debugging
    cargo build &>/tmp/cargo-build-output
    let build_exit = $?

    if test $build_exit = 0
      echo "FUNC_TEST:cargo-build:PASS"
    else
      echo "FUNC_TEST:cargo-build:FAIL:cargo build exited $build_exit"
      echo "=== cargo build output ==="
      cat /tmp/cargo-build-output
      echo "=== end cargo output ==="
    end

    # Test: the built binary exists
    if exists -f target/x86_64-unknown-redox/debug/hello
      echo "FUNC_TEST:binary-exists:PASS"
    else
      echo "FUNC_TEST:binary-exists:FAIL:target binary not found"
    end

    # Test: the built binary runs and produces correct output
    if exists -f target/x86_64-unknown-redox/debug/hello
      let output = $(target/x86_64-unknown-redox/debug/hello 2>/dev/null)
      if test $output = "Hello from self-hosted Redox!"
        echo "FUNC_TEST:binary-runs:PASS"
      else
        echo "FUNC_TEST:binary-runs:FAIL:unexpected output"
      end
    else
      echo "FUNC_TEST:binary-runs:SKIP"
    end

    echo ""
    echo "FUNC_TESTS_COMPLETE"
  '';

  # Build from the self-hosting profile
  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };
in
selfHosting
// {
  # Override boot to use a larger disk (more room for build artifacts)
  "/boot" = (selfHosting."/boot" or { }) // {
    diskSizeMB = 4096;
  };

  # Disable interactive login — just run the test script
  "/services" = (selfHosting."/services" or { }) // {
    startupScriptText = testScript;
  };

  # No userutils — run the test script directly (not via getty)
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
