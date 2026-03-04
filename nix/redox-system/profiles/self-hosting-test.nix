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

  # No external test source files needed — written inline via Ion echo

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
    rustc --print cfg >/tmp/rustc-print-cfg-out
    let print_cfg_exit = $?
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
      # Allocator shim: provides __rust_alloc → __rdl_alloc etc.
      if exists -f /usr/lib/redox-sysroot/lib/liballoc_shim.a
        echo "/usr/lib/redox-sysroot/lib/liballoc_shim.a" >> /tmp/link-args.txt
      end
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
      if exists -f /usr/lib/redox-sysroot/lib/liballoc_shim.a
        echo "/usr/lib/redox-sysroot/lib/liballoc_shim.a" >> /tmp/hello-link-args.txt
      end
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
        # Run and capture output to file (Ion $() may lose output on crash)
        /tmp/hello-linked > /tmp/hello-run-out ^>/tmp/hello-run-err
        let hello_run_exit = $?
        echo "Hello run exit: $hello_run_exit"
        echo "Hello stdout:"
        cat /tmp/hello-run-out
        echo "Hello stderr:"
        cat /tmp/hello-run-err
        let hello_out = $(cat /tmp/hello-run-out)
        if test "$hello_out" = "hello"
          echo "FUNC_TEST:hello-two-step:PASS"
        else
          echo "FUNC_TEST:hello-two-step:FAIL:exit=$hello_run_exit output=$hello_out"
        end
      else
        echo "FUNC_TEST:hello-two-step:FAIL:link failed"
      end
    else
      echo "FUNC_TEST:hello-two-step:FAIL:compile failed"
    end

    # ── Step 4c: Allocator shim test ──
    echo "--- Step 4c: Allocator shim presence ---"
    if exists -f /usr/lib/redox-sysroot/lib/liballoc_shim.a
      echo "FUNC_TEST:alloc-shim:PASS"
    else
      echo "FUNC_TEST:alloc-shim:FAIL:liballoc_shim.a not found"
    end

    # ── Step 4d: Fork/pipe diagnostics (before risky cargo build) ──
    echo "--- Step 4d: Fork/pipe diagnostics ---"

    # Test: can bash fork+exec rustc? (kernel fork, not Rust Command)
    echo "Test: bash fork rustc -vV..."
    /nix/system/profile/bin/bash -c 'rustc -vV > /tmp/bash-rustc-vv 2>&1; echo "exit=$?"' > /tmp/bash-fork-out ^>/dev/null
    echo "FUNC_TEST:bash-fork-rustc:$(cat /tmp/bash-fork-out)"
    cat /tmp/bash-rustc-vv

    # Test: rustc with --error-format=json (what cargo uses)
    echo "Test: rustc --emit=obj --error-format=json..."
    rustc /tmp/empty.rs --emit=obj -o /tmp/empty-json.o --error-format=json > /tmp/rustc-json-stdout ^>/tmp/rustc-json-stderr
    echo "FUNC_TEST:rustc-json-format:exit=$?"

    # Test: rustc with piped output (simulate cargo's pipe capture)
    echo "Test: rustc --emit=obj through pipe..."
    /nix/system/profile/bin/bash -c 'rustc /tmp/empty.rs --emit=obj -o /tmp/empty-pipe.o 2>/tmp/pipe-stderr' > /tmp/pipe-stdout
    echo "FUNC_TEST:rustc-piped:exit=$?"

    # Test: rustc --emit=obj with --message-format=json (full cargo mode)
    echo "Test: rustc with message-format json..."
    rustc /tmp/empty.rs --emit=obj -o /tmp/empty-msgfmt.o --error-format=json --json=diagnostic-rendered-ansi > /tmp/rustc-msgfmt-stdout ^>/tmp/rustc-msgfmt-stderr
    echo "FUNC_TEST:rustc-message-format:exit=$?"

    # Test: unset LD_DEBUG before running rustc (might interfere)
    echo "Unsetting LD_DEBUG..."
    drop LD_DEBUG
    rustc /tmp/empty.rs --emit=obj -o /tmp/empty-nold.o > /tmp/rustc-nold-stdout ^>/tmp/rustc-nold-stderr
    echo "FUNC_TEST:rustc-no-ld-debug:exit=$?"

    # ── Step 4e: cargo build ──
    echo "--- Step 4e: cargo build ---"

    cargo version > /tmp/cargo-version-out ^>/tmp/cargo-version-err
    echo "cargo version exit: $?"
    cat /tmp/cargo-version-out

    # Replicate what cargo does — invoke rustc through Command::output()
    # Write Rust source via Ion echo (single-quoted = no expansion).
    echo 'use std::process::Command;' > /tmp/fork_test.rs
    echo 'fn main() {' >> /tmp/fork_test.rs
    echo '    match Command::new("rustc").args(&["-vV"]).output() {' >> /tmp/fork_test.rs
    echo '        Ok(o) => {' >> /tmp/fork_test.rs
    echo '            println!("exit: {}", o.status);' >> /tmp/fork_test.rs
    echo '            println!("stdout: {}", String::from_utf8_lossy(&o.stdout));' >> /tmp/fork_test.rs
    echo '            if !o.stderr.is_empty() {' >> /tmp/fork_test.rs
    echo '                println!("stderr: {}", String::from_utf8_lossy(&o.stderr));' >> /tmp/fork_test.rs
    echo '            }' >> /tmp/fork_test.rs
    echo '        }' >> /tmp/fork_test.rs
    echo '        Err(e) => println!("spawn error: {}", e),' >> /tmp/fork_test.rs
    echo '    }' >> /tmp/fork_test.rs
    echo '}' >> /tmp/fork_test.rs

    echo "Compiling fork test program (two-step)..."
    rustc /tmp/fork_test.rs --emit=obj -o /tmp/fork_test.o ^>/dev/null
    let fork_test_compile = $?
    echo "Fork test compile: $fork_test_compile"

    if test $fork_test_compile = 0
      let sysroot = $(rustc --print sysroot)
      let target_lib = "$sysroot/lib/rustlib/x86_64-unknown-redox/lib"

      echo "/usr/lib/redox-sysroot/lib/crt0.o" > /tmp/fork-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crti.o" >> /tmp/fork-link-args.txt
      echo "/tmp/fork_test.o" >> /tmp/fork-link-args.txt
      /nix/system/profile/bin/bash -c "ls $target_lib/*.rlib" >> /tmp/fork-link-args.txt
      echo "-L" >> /tmp/fork-link-args.txt
      echo "/usr/lib/redox-sysroot/lib" >> /tmp/fork-link-args.txt
      echo "-l:libc.a" >> /tmp/fork-link-args.txt
      echo "-l:libpthread.a" >> /tmp/fork-link-args.txt
      echo "-l:libgcc_eh.a" >> /tmp/fork-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/liballoc_shim.a" >> /tmp/fork-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crtn.o" >> /tmp/fork-link-args.txt
      echo "-o" >> /tmp/fork-link-args.txt
      echo "/tmp/fork_test" >> /tmp/fork-link-args.txt

      /nix/system/profile/bin/bash -c '/nix/system/profile/bin/ld.lld @/tmp/fork-link-args.txt' ^>/tmp/fork-link-err
      let fork_link = $?
      echo "Fork test link: $fork_link"

      if test $fork_link = 0
        echo "Running fork test (Rust Command::output() → rustc -vV)..."
        /tmp/fork_test > /tmp/fork-test-out ^>/tmp/fork-test-err
        let fork_run = $?
        echo "Fork test exit: $fork_run"
        cat /tmp/fork-test-out
        if test $fork_run = 0
          echo "FUNC_TEST:rust-command-fork:PASS"
        else
          echo "FUNC_TEST:rust-command-fork:FAIL:exit=$fork_run"
          cat /tmp/fork-test-err
        end
      else
        echo "FUNC_TEST:rust-command-fork:FAIL:link failed"
        cat /tmp/fork-link-err
      end
    else
      echo "FUNC_TEST:rust-command-fork:FAIL:compile failed"
    end

    # ── Cargo crash diagnostics ──
    # Cargo build crashes when it invokes rustc as subprocess.
    # Build a compiled RUSTC wrapper that logs args/env before exec.

    # Write the wrapper source (uses Ion echo to avoid Nix escaping)
    # Spy mode 1: just log and exit 0 (capture what cargo passes)
    echo 'use std::io::Write;' > /tmp/rustc_spy.rs
    echo 'fn main() {' >> /tmp/rustc_spy.rs
    echo '    let args: Vec<String> = std::env::args().collect();' >> /tmp/rustc_spy.rs
    echo '    if let Ok(mut f) = std::fs::OpenOptions::new()' >> /tmp/rustc_spy.rs
    echo '        .create(true).append(true)' >> /tmp/rustc_spy.rs
    echo '        .open("/tmp/rustc-spy.log") {' >> /tmp/rustc_spy.rs
    echo '        let _ = writeln!(f, "=== RUSTC SPY CALL ===");' >> /tmp/rustc_spy.rs
    echo '        let _ = writeln!(f, "ARGS: {:?}", &args[1..]);' >> /tmp/rustc_spy.rs
    echo '        for (k, v) in std::env::vars() {' >> /tmp/rustc_spy.rs
    echo '            if k.starts_with("CARGO") || k.starts_with("RUST")' >> /tmp/rustc_spy.rs
    echo '                || k == "PATH" || k.starts_with("LD_") {' >> /tmp/rustc_spy.rs
    echo '                let _ = writeln!(f, "ENV: {}={}", k, v);' >> /tmp/rustc_spy.rs
    echo '            }' >> /tmp/rustc_spy.rs
    echo '        }' >> /tmp/rustc_spy.rs
    echo '        let _ = f.flush();' >> /tmp/rustc_spy.rs
    echo '    }' >> /tmp/rustc_spy.rs
    echo '    // If cargo asks for -vV, fake the version output' >> /tmp/rustc_spy.rs
    echo '    if args.iter().any(|a| a == "-vV") {' >> /tmp/rustc_spy.rs
    echo '        println!("rustc 1.92.0-nightly (5c7ae0c7e 2025-10-02)");' >> /tmp/rustc_spy.rs
    echo '        println!("binary: rustc");' >> /tmp/rustc_spy.rs
    echo '        println!("commit-hash: 5c7ae0c7ed184c603e5224604a9f33ca0e8e0b36");' >> /tmp/rustc_spy.rs
    echo '        println!("commit-date: 2025-10-02");' >> /tmp/rustc_spy.rs
    echo '        println!("host: x86_64-unknown-redox");' >> /tmp/rustc_spy.rs
    echo '        println!("release: 1.92.0-nightly");' >> /tmp/rustc_spy.rs
    echo '        println!("LLVM version: 21.1.2");' >> /tmp/rustc_spy.rs
    echo '    }' >> /tmp/rustc_spy.rs
    echo '    // For everything else, exit 1 so cargo stops' >> /tmp/rustc_spy.rs
    echo '    if !args.iter().any(|a| a == "-vV") {' >> /tmp/rustc_spy.rs
    echo '        std::process::exit(1);' >> /tmp/rustc_spy.rs
    echo '    }' >> /tmp/rustc_spy.rs
    echo '}' >> /tmp/rustc_spy.rs

    echo "Compiling rustc-spy wrapper..."
    rustc /tmp/rustc_spy.rs --emit=obj -o /tmp/rustc_spy.o ^>/dev/null
    let spy_compile = $?
    echo "rustc-spy compile: $spy_compile"

    if test $spy_compile = 0
      let sysroot = $(rustc --print sysroot)
      let target_lib = "$sysroot/lib/rustlib/x86_64-unknown-redox/lib"
      echo "/usr/lib/redox-sysroot/lib/crt0.o" > /tmp/spy-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crti.o" >> /tmp/spy-link-args.txt
      echo "/tmp/rustc_spy.o" >> /tmp/spy-link-args.txt
      /nix/system/profile/bin/bash -c "ls $target_lib/*.rlib" >> /tmp/spy-link-args.txt
      echo "-L" >> /tmp/spy-link-args.txt
      echo "/usr/lib/redox-sysroot/lib" >> /tmp/spy-link-args.txt
      echo "-l:libc.a" >> /tmp/spy-link-args.txt
      echo "-l:libpthread.a" >> /tmp/spy-link-args.txt
      echo "-l:libgcc_eh.a" >> /tmp/spy-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/liballoc_shim.a" >> /tmp/spy-link-args.txt
      echo "/usr/lib/redox-sysroot/lib/crtn.o" >> /tmp/spy-link-args.txt
      echo "-o" >> /tmp/spy-link-args.txt
      echo "/tmp/rustc-spy" >> /tmp/spy-link-args.txt
      /nix/system/profile/bin/bash -c '/nix/system/profile/bin/ld.lld @/tmp/spy-link-args.txt' ^>/tmp/spy-link-err
      let spy_link = $?
      echo "rustc-spy link: $spy_link"

      if test $spy_link = 0
        # Quick test: rustc-spy -vV (should work like normal rustc)
        /tmp/rustc-spy -vV > /tmp/spy-test-out ^>/tmp/spy-test-err
        echo "rustc-spy test: exit=$?"

        # Now use it as RUSTC for cargo
        echo "--- cargo build with rustc-spy ---"
        /nix/system/profile/bin/bash -c '
          cd /tmp/hello
          export RUSTC=/tmp/rustc-spy
          cargo build 2>/tmp/cargo-spy-stderr
          echo "spy-cargo-exit=$?"
        ' > /tmp/cargo-spy-out
        cat /tmp/cargo-spy-out

        echo "=== rustc-spy log ==="
        if test -f /tmp/rustc-spy.log
          cat /tmp/rustc-spy.log
        else
          echo "(no log file created)"
        end

        echo "=== cargo stderr (first 1000b) ==="
        if test -f /tmp/cargo-spy-stderr
          head -c 1000 /tmp/cargo-spy-stderr
        end
      else
        echo "rustc-spy link failed"
        cat /tmp/spy-link-err
      end
    else
      echo "rustc-spy compile failed"
    end

    # Check .so load addresses: LD_DEBUG=load shows where ld_so maps libraries
    echo "--- LD_DEBUG=load: rustc from shell ---"
    /nix/system/profile/bin/bash -c 'LD_DEBUG=load /nix/system/profile/bin/rustc -vV >/tmp/ld-debug-shell-out 2>/tmp/ld-debug-shell-err'
    echo "LD_DEBUG rustc from shell: exit=$?"
    cat /tmp/ld-debug-shell-err

    # Now replicate cargo's exact third rustc invocation from the shell
    echo "--- Replicate cargo's probe command ---"
    echo "" | rustc - --crate-name ___ --print=file-names --crate-type bin --crate-type rlib --crate-type dylib --crate-type cdylib --crate-type staticlib --crate-type proc-macro --print=sysroot --print=split-debuginfo --print=crate-name --print=cfg -Wwarnings > /tmp/cargo-probe-out ^>/tmp/cargo-probe-err
    let probe_exit = $?
    echo "cargo probe command exit: $probe_exit"
    if test $probe_exit = 0
      echo "FUNC_TEST:cargo-probe-cmd:PASS"
      head -c 500 /tmp/cargo-probe-out
    else
      echo "FUNC_TEST:cargo-probe-cmd:FAIL:exit=$probe_exit"
      head -c 500 /tmp/cargo-probe-err
    end

    # Test: same command with RUST_BACKTRACE=1 (cargo sets this)
    echo "--- cargo probe with RUST_BACKTRACE=1 ---"
    export RUST_BACKTRACE=1
    echo "" | rustc - --crate-name ___ --print=file-names --crate-type bin --crate-type rlib --crate-type dylib --crate-type cdylib --crate-type staticlib --crate-type proc-macro --print=sysroot --print=split-debuginfo --print=crate-name --print=cfg -Wwarnings > /tmp/cargo-probe-bt-out ^>/tmp/cargo-probe-bt-err
    let probe_bt_exit = $?
    drop RUST_BACKTRACE
    echo "cargo probe with RUST_BACKTRACE exit: $probe_bt_exit"
    if test $probe_bt_exit = 0
      echo "FUNC_TEST:cargo-probe-bt:PASS"
    else
      echo "FUNC_TEST:cargo-probe-bt:FAIL:exit=$probe_bt_exit"
      head -c 500 /tmp/cargo-probe-bt-err
    end

    # Spy2: simple pass-through that closes FDs 3-1023 before exec
    # Tests whether cargo's inherited FDs cause the crash.
    echo 'use std::io::Write;' > /tmp/rustc_spy2.rs
    echo 'use std::process::Command;' >> /tmp/rustc_spy2.rs
    echo 'fn main() {' >> /tmp/rustc_spy2.rs
    echo '    let args: Vec<String> = std::env::args().collect();' >> /tmp/rustc_spy2.rs
    echo '    {' >> /tmp/rustc_spy2.rs
    echo '        if let Ok(mut f) = std::fs::OpenOptions::new()' >> /tmp/rustc_spy2.rs
    echo '            .create(true).append(true)' >> /tmp/rustc_spy2.rs
    echo '            .open("/tmp/rustc-spy2.log") {' >> /tmp/rustc_spy2.rs
    echo '            let _ = writeln!(f, "SPY2: {:?}", &args[1..]);' >> /tmp/rustc_spy2.rs
    echo '            let _ = f.flush();' >> /tmp/rustc_spy2.rs
    echo '        }' >> /tmp/rustc_spy2.rs
    echo '    }' >> /tmp/rustc_spy2.rs
    echo '    // Close ALL inherited FDs above stderr' >> /tmp/rustc_spy2.rs
    echo '    extern "C" { fn close(fd: i32) -> i32; }' >> /tmp/rustc_spy2.rs
    echo '    for fd in 3..256i32 {' >> /tmp/rustc_spy2.rs
    echo '        unsafe { close(fd); }' >> /tmp/rustc_spy2.rs
    echo '    }' >> /tmp/rustc_spy2.rs
    echo '    let status = Command::new("/nix/system/profile/bin/rustc")' >> /tmp/rustc_spy2.rs
    echo '        .args(&args[1..])' >> /tmp/rustc_spy2.rs
    echo '        .status();' >> /tmp/rustc_spy2.rs
    echo '    match status {' >> /tmp/rustc_spy2.rs
    echo '        Ok(s) => std::process::exit(s.code().unwrap_or(1)),' >> /tmp/rustc_spy2.rs
    echo '        Err(e) => {' >> /tmp/rustc_spy2.rs
    echo '            eprintln!("spy2: {}", e);' >> /tmp/rustc_spy2.rs
    echo '            std::process::exit(1);' >> /tmp/rustc_spy2.rs
    echo '        }' >> /tmp/rustc_spy2.rs
    echo '    }' >> /tmp/rustc_spy2.rs
    echo '}' >> /tmp/rustc_spy2.rs

    echo "Compiling rustc-spy2..."
    rustc /tmp/rustc_spy2.rs --emit=obj -o /tmp/rustc_spy2.o ^>/dev/null
    if test $? = 0
      let sysroot = $(rustc --print sysroot)
      let target_lib = "$sysroot/lib/rustlib/x86_64-unknown-redox/lib"
      echo "/usr/lib/redox-sysroot/lib/crt0.o" > /tmp/spy2-link.txt
      echo "/usr/lib/redox-sysroot/lib/crti.o" >> /tmp/spy2-link.txt
      echo "/tmp/rustc_spy2.o" >> /tmp/spy2-link.txt
      /nix/system/profile/bin/bash -c "ls $target_lib/*.rlib" >> /tmp/spy2-link.txt
      echo "-L" >> /tmp/spy2-link.txt
      echo "/usr/lib/redox-sysroot/lib" >> /tmp/spy2-link.txt
      echo "-l:libc.a" >> /tmp/spy2-link.txt
      echo "-l:libpthread.a" >> /tmp/spy2-link.txt
      echo "-l:libgcc_eh.a" >> /tmp/spy2-link.txt
      echo "/usr/lib/redox-sysroot/lib/liballoc_shim.a" >> /tmp/spy2-link.txt
      echo "/usr/lib/redox-sysroot/lib/crtn.o" >> /tmp/spy2-link.txt
      echo "-o" >> /tmp/spy2-link.txt
      echo "/tmp/rustc-spy2" >> /tmp/spy2-link.txt
      /nix/system/profile/bin/bash -c '/nix/system/profile/bin/ld.lld @/tmp/spy2-link.txt' ^>/dev/null
      if test $? = 0
        echo "--- cargo build with FD-closing spy2 ---"
        /nix/system/profile/bin/bash -c '
          cd /tmp/hello
          export RUSTC=/tmp/rustc-spy2
          cargo build 2>/tmp/cargo-spy2-stderr
          echo "spy2-exit=$?"
        ' > /tmp/cargo-spy2-out
        cat /tmp/cargo-spy2-out
        if test -f /tmp/rustc-spy2.log
          echo "=== spy2 log ==="
          cat /tmp/rustc-spy2.log
        end
      else
        echo "spy2 link failed"
      end
    else
      echo "spy2 compile failed"
    end

    echo "FUNC_TEST:cargo-build:FAIL:investigating"

    # ── Step 4f: subprocess fork tests (RISKY — may crash) ──
    echo "--- Step 4f: fork diagnostics ---"

    # Test: can bash fork rustc? (tests kernel fork, not Rust Command)
    echo "Testing: bash -c 'rustc -vV' (bash fork, not Rust Command)..."
    /nix/system/profile/bin/bash -c 'rustc -vV > /tmp/bash-rustc-out 2>&1'
    echo "FUNC_TEST:bash-fork-rustc:exit=$?"
    cat /tmp/bash-rustc-out

    # Test: rustc with echo linker (exits instantly)
    echo "Testing /bin/echo as linker..."
    rustc /tmp/empty.rs -o /tmp/empty-echo -C linker=/bin/echo -C linker-flavor=gcc &>/tmp/rustc-echo-out
    echo "FUNC_TEST:echo-linker:exit=$?"

    # Test: rustc --emit=obj through bash (no linking, just LLVM)
    echo "Testing: bash -c 'rustc --emit=obj' (rustc as subprocess, no link)..."
    /nix/system/profile/bin/bash -c 'rustc /tmp/empty.rs --emit=obj -o /tmp/empty-bash.o > /tmp/bash-rustc-obj-out 2>&1'
    echo "FUNC_TEST:bash-fork-rustc-obj:exit=$?"

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
