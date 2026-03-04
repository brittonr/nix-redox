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

    # ── Diagnostics: PATH and cc availability ─────────────
    echo "=== PATH diagnostics ==="
    echo "PATH = $PATH"
    echo "--- cc binary check ---"
    if exists -f /nix/system/profile/bin/cc
      echo "cc exists at /nix/system/profile/bin/cc"
    else
      echo "cc NOT found at /nix/system/profile/bin/cc"
    end
    # Check symlink target
    ls -la /nix/system/profile/bin/cc
    # Try running cc directly from shell
    echo "--- cc --version from shell ---"
    /nix/system/profile/bin/cc --version ^>/dev/null
    echo "cc direct exit: $?"

    # ── Diagnostics: clang directly ────────────────────────
    # Narrow down clang failure: test small vs large clang tools
    # clang-format (5.9MB, no codegen) and clang-tblgen (4.3MB)
    echo "--- clang-format --version ---"
    /nix/system/profile/bin/clang-format --version &>/tmp/clang-format-out
    echo "clang-format exit: $?"
    cat /tmp/clang-format-out

    echo "--- diagtool --version ---"
    /nix/system/profile/bin/diagtool &>/tmp/diagtool-out
    echo "diagtool exit: $?"
    cat /tmp/diagtool-out

    # llc --version with merged output to see targets
    echo "--- llc --version (merged) ---"
    /nix/system/profile/bin/llc --version &>/tmp/llc-out
    echo "llc exit: $?"
    cat /tmp/llc-out

    # Try clang-21 --help-hidden (different code path than --version)
    echo "--- clang-21 --help (first 5 lines) ---"
    /nix/system/profile/bin/clang-21 --help &>/tmp/clang-help-out
    echo "clang --help exit: $?"
    head -c 200 /tmp/clang-help-out

    # Try clang-scan-deps (uses Clang frontend but not driver)
    echo "--- clang-scan-deps --version ---"
    /nix/system/profile/bin/clang-scan-deps --version &>/tmp/csd-out
    echo "clang-scan-deps exit: $?"
    cat /tmp/csd-out

    # ld.lld + llvm-ar still work (confirms stack growth)
    /nix/system/profile/bin/ld.lld --version &>/dev/null
    echo "ld.lld: $?"
    /nix/system/profile/bin/llvm-ar --version &>/dev/null
    echo "llvm-ar: $?"

    ls -la /nix/system/profile/bin/clang /nix/system/profile/bin/clang-21

    # Try lld too
    echo "--- lld --version directly ---"
    /nix/system/profile/bin/lld --version >/tmp/lld-stdout ^>/tmp/lld-stderr
    let lld_exit = $?
    echo "lld exit: $lld_exit"
    echo "lld stdout:"
    cat /tmp/lld-stdout
    echo "lld stderr:"
    cat /tmp/lld-stderr

    # Try clang-21 directly (resolving symlink chain)
    echo "--- clang-21 direct test ---"
    # Find clang-21 via the profile symlink chain
    ls -la /nix/system/profile/bin/clang
    # Try ld.lld --version (lld expects to be invoked as ld.lld)
    echo "--- ld.lld --version ---"
    /nix/system/profile/bin/ld.lld --version >/tmp/ld-lld-stdout ^>/tmp/ld-lld-stderr
    let ld_lld_exit = $?
    echo "ld.lld exit: $ld_lld_exit"
    echo "ld.lld stdout:"
    cat /tmp/ld-lld-stdout
    echo "ld.lld stderr:"
    cat /tmp/ld-lld-stderr

    # Try llvm-ar --version (simpler tool, less stack)
    echo "--- llvm-ar --version ---"
    /nix/system/profile/bin/llvm-ar --version >/tmp/llvm-ar-stdout ^>/tmp/llvm-ar-stderr
    let llvm_ar_exit = $?
    echo "llvm-ar exit: $llvm_ar_exit"
    echo "llvm-ar stdout:"
    cat /tmp/llvm-ar-stdout

    # ── Separate compilation from linking ──────────────────
    # Compile to object file first (no linker needed), then link separately.
    # This pinpoints whether the crash is in LLVM codegen or linking.

    echo "--- Step 1: rustc --emit=obj (compile only, no linker) ---"
    echo 'fn main() { }' > /tmp/empty.rs
    rustc /tmp/empty.rs --emit=obj -o /tmp/empty.o &>/tmp/rustc-emit-obj-out
    let emit_obj_exit = $?
    echo "rustc --emit=obj exit: $emit_obj_exit"
    if test $emit_obj_exit != 0
      echo "=== rustc --emit=obj output ==="
      cat /tmp/rustc-emit-obj-out
      echo "=== end ==="
    else
      echo "Object file created successfully"
      ls -la /tmp/empty.o
    end

    echo "--- Step 1b: rustc --emit=obj with println ---"
    echo 'fn main() { println!("hello"); }' > /tmp/hello.rs
    rustc /tmp/hello.rs --emit=obj -o /tmp/hello.o &>/tmp/rustc-hello-obj-out
    let hello_obj_exit = $?
    echo "rustc --emit=obj hello exit: $hello_obj_exit"
    if test $hello_obj_exit != 0
      cat /tmp/rustc-hello-obj-out
    else
      ls -la /tmp/hello.o
    end

    echo "--- Step 2: Link with ld.lld directly ---"
    if test $emit_obj_exit = 0
      /nix/system/profile/bin/ld.lld --static \
        /usr/lib/redox-sysroot/lib/crt0.o \
        /usr/lib/redox-sysroot/lib/crti.o \
        /tmp/empty.o \
        -L /usr/lib/redox-sysroot/lib \
        -l:libc.a -l:libpthread.a \
        /usr/lib/redox-sysroot/lib/crtn.o \
        -o /tmp/empty-bin &>/tmp/lld-link-out
      let link_exit = $?
      echo "ld.lld link exit: $link_exit"
      if test $link_exit != 0
        echo "=== ld.lld output ==="
        cat /tmp/lld-link-out
        echo "=== end ==="
      else
        ls -la /tmp/empty-bin
      end
    end

    echo "--- Step 3: Link via CC wrapper ---"
    if test $emit_obj_exit = 0
      /nix/system/profile/bin/cc /tmp/empty.o -o /tmp/empty-cc &>/tmp/cc-link-out
      let cc_link_exit = $?
      echo "CC wrapper link exit: $cc_link_exit"
      if test $cc_link_exit != 0
        cat /tmp/cc-link-out
      end
    end

    echo "--- Step 3b: Rust sysroot contents ---"
    let rust_sysroot = $(rustc --print sysroot)
    echo "Rust sysroot: $rust_sysroot"
    echo "Rust target lib dir:"
    ls $rust_sysroot/lib/rustlib/x86_64-unknown-redox/lib/ ^>/dev/null
    echo "---"

    echo "--- Step 3c: Show cargo config ---"
    cat /root/.cargo/config.toml

    echo "--- Step 3d: Link with ld.lld + all Rust libs ---"
    /nix/system/profile/bin/ld.lld /usr/lib/redox-sysroot/lib/crt0.o /usr/lib/redox-sysroot/lib/crti.o /tmp/empty.o -L $rust_sysroot/lib/rustlib/x86_64-unknown-redox/lib -L /usr/lib/redox-sysroot/lib -l:libc.a -l:libpthread.a /usr/lib/redox-sysroot/lib/crtn.o -o /tmp/empty-lld &>/tmp/lld-full-out
    let lld_full_exit = $?
    echo "ld.lld manual link exit: $lld_full_exit"
    cat /tmp/lld-full-out

    # ── Linker tests: safe first, risky last ──────────────
    # The rustc linker invocation may crash the process (Invalid opcode in
    # fork/waitpid on Redox). Run safe tests first to get results.

    # ── Step 4a: Two-step compile+link (SAFE — no rustc subprocess) ──
    echo "--- Step 4a: Two-step compile+link ---"
    rustc /tmp/empty.rs --emit=obj -o /tmp/empty-step.o &>/tmp/rustc-step1-out
    let step1_exit = $?
    echo "Compile (emit=obj): $step1_exit"

    let step2_exit = 1
    if test $step1_exit = 0
      let sysroot = $(rustc --print sysroot)
      let target_lib = "$sysroot/lib/rustlib/x86_64-unknown-redox/lib"

      # Write ld.lld response file — one arg per line
      # (Ion treats $string as a single arg; use a response file to avoid this)
      echo "/usr/lib/redox-sysroot/lib/crt0.o" > /tmp/link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crti.o" >> /tmp/link-args.txt
      echo "/tmp/empty-step.o" >> /tmp/link-args.txt
      # Include only .rlib files — write a bash script to filter
      # (Ion can't pipe inside @() and find isn't available on Redox)
      /nix/system/profile/bin/bash -c "ls $target_lib/*.rlib" >> /tmp/link-args.txt
      echo "-L" >> /tmp/link-args.txt
      echo "/usr/lib/redox-sysroot/lib" >> /tmp/link-args.txt
      echo "-l:libc.a" >> /tmp/link-args.txt
      echo "-l:libpthread.a" >> /tmp/link-args.txt
      echo "-l:libgcc_eh.a" >> /tmp/link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crtn.o" >> /tmp/link-args.txt
      echo "-o" >> /tmp/link-args.txt
      echo "/tmp/empty-linked" >> /tmp/link-args.txt

      echo "Link args:"
      cat /tmp/link-args.txt

      echo "Linking with rlibs from: $target_lib"
      # Use bash to invoke ld.lld with response file (Ion interprets @ as array sigil)
      /nix/system/profile/bin/bash -c '/nix/system/profile/bin/ld.lld @/tmp/link-args.txt' &>/tmp/lld-step2-out
      let step2_exit = $?
      echo "Link (ld.lld): $step2_exit"
      if test $step2_exit != 0
        cat /tmp/lld-step2-out
      end
    end

    if test $step2_exit = 0
      if exists -f /tmp/empty-linked
        /tmp/empty-linked &>/tmp/linked-run-out
        let run_exit = $?
        echo "Run linked binary: exit $run_exit"
        echo "FUNC_TEST:two-step-compile:PASS"
      else
        echo "FUNC_TEST:two-step-compile:FAIL:binary not created"
      end
    else
      echo "FUNC_TEST:two-step-compile:FAIL:step1=$step1_exit step2=$step2_exit"
    end

    # ── Step 4b: Hello world two-step ──
    echo "--- Step 4b: Hello world two-step ---"
    rustc /tmp/hello.rs --emit=obj -o /tmp/hello-step.o &>/tmp/rustc-hello-step1-out
    let hello_step1 = $?
    echo "Hello compile: $hello_step1"

    if test $hello_step1 = 0
      let sysroot = $(rustc --print sysroot)
      let target_lib = "$sysroot/lib/rustlib/x86_64-unknown-redox/lib"

      echo "/usr/lib/redox-sysroot/lib/crt0.o" > /tmp/hello-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crti.o" >> /tmp/hello-link-args.txt
      echo "/tmp/hello-step.o" >> /tmp/hello-link-args.txt
      /nix/system/profile/bin/bash -c "ls $target_lib/*.rlib" >> /tmp/hello-link-args.txt
      echo "-L" >> /tmp/hello-link-args.txt
      echo "/usr/lib/redox-sysroot/lib" >> /tmp/hello-link-args.txt
      echo "-l:libc.a" >> /tmp/hello-link-args.txt
      echo "-l:libpthread.a" >> /tmp/hello-link-args.txt
      echo "-l:libgcc_eh.a" >> /tmp/hello-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crtn.o" >> /tmp/hello-link-args.txt
      echo "-o" >> /tmp/hello-link-args.txt
      echo "/tmp/hello-linked" >> /tmp/hello-link-args.txt

      /nix/system/profile/bin/bash -c '/nix/system/profile/bin/ld.lld @/tmp/hello-link-args.txt' &>/tmp/lld-hello-out
      let hello_step2 = $?
      echo "Hello link: $hello_step2"
      if test $hello_step2 != 0
        cat /tmp/lld-hello-out
      end

      if test $hello_step2 = 0
        let hello_out = $(/tmp/hello-linked 2>/dev/null)
        echo "Hello output: $hello_out"
        if test "$hello_out" = "Hello from self-hosted Redox!"
          echo "FUNC_TEST:hello-two-step:PASS"
        else
          echo "FUNC_TEST:hello-two-step:FAIL:wrong output: $hello_out"
        end
      else
        echo "FUNC_TEST:hello-two-step:FAIL:link failed"
      end
    else
      echo "FUNC_TEST:hello-two-step:FAIL:compile failed"
    end

    # ── Step 4c: rustc with ld.lld direct (linker-flavor) ──
    echo "--- Step 4c: rustc with ld.lld direct ---"
    echo "Testing /bin/echo as linker first (baseline)..."
    rustc /tmp/empty.rs -o /tmp/empty-echo -C linker=/bin/echo -C linker-flavor=gcc &>/tmp/rustc-echo-out
    echo "echo linker: $?"

    echo "Testing ld.lld as linker via linker-flavor..."
    rustc /tmp/empty.rs -o /tmp/empty-lld -Z unstable-options -C linker-flavor=gnu-lld-cc -C linker=/nix/system/profile/bin/cc &>/tmp/rustc-lld-out
    let lld_direct_exit = $?
    echo "ld.lld direct: $lld_direct_exit"
    if test $lld_direct_exit != 0
      cat /tmp/rustc-lld-out
    end

    # ── Step 4d: Subprocess diagnostics ──
    echo "--- Step 4d: Subprocess timing diagnostics ---"
    echo "Test: /bin/true as linker"
    rustc /tmp/empty.rs -o /tmp/empty-true -C linker=/bin/true -C linker-flavor=gcc &>/tmp/rustc-true-out
    echo "true linker: $?"

    echo "Test: /bin/cat as linker (will fail but should not crash)"
    rustc /tmp/empty.rs -o /tmp/empty-cat -C linker=/bin/cat -C linker-flavor=gcc &>/tmp/rustc-cat-out
    echo "cat linker: $?"

    # ── Step 4e: cargo build ──
    echo "--- Step 4e: cargo build ---"
    echo "cargo config:"
    cat /root/.cargo/config.toml
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

    # Test: the built binary exists and runs
    if exists -f target/x86_64-unknown-redox/debug/hello
      echo "FUNC_TEST:binary-exists:PASS"
      let output = $(target/x86_64-unknown-redox/debug/hello 2>/dev/null)
      if test "$output" = "Hello from self-hosted Redox!"
        echo "FUNC_TEST:binary-runs:PASS"
      else
        echo "FUNC_TEST:binary-runs:FAIL:unexpected output: $output"
      end
    else
      echo "FUNC_TEST:binary-exists:FAIL"
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
