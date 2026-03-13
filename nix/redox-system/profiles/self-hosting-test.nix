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
                        # Ion's @(ls)+matches is unreliable for glob detection; use bash glob instead
                        let driver_found = $(bash -c 'ls /usr/lib/rustc/librustc_driver*.so /nix/system/profile/lib/librustc_driver*.so /lib/librustc_driver*.so 2>/dev/null | head -1')
                        if not test $driver_found = ""
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
                        # CARGO_BUILD_JOBS: JOBS=2 works since fork-lock + lld-wrapper fixes
                        # CARGO_HOME: cargo needs a writable config dir
                        let LD_LIBRARY_PATH = "/nix/system/profile/lib:/usr/lib/rustc:/lib"
                        export LD_LIBRARY_PATH
                        let CARGO_BUILD_JOBS = "2"
                        export CARGO_BUILD_JOBS
                        # CARGO_HOME must be /root/.cargo where config.toml lives
                        # (config.toml has linker=ld.lld and rustflags for Redox target)
                        let CARGO_HOME = "/root/.cargo"
                        export CARGO_HOME

                        # Create a cargo-build wrapper with timeout+retry
                        # Cargo sometimes hangs on relibc's broken flock() implementation.
                        # This wrapper runs cargo in background, kills after 90s, retries once.
                        /nix/system/profile/bin/bash -c 'printf "#!/nix/system/profile/bin/bash\nMAX_TIME=90\nfor attempt in 1 2; do\n  cargo build --offline \"\$@\" &\n  PID=\$!\n  SECONDS=0\n  while kill -0 \$PID 2>/dev/null; do\n    if [ \$SECONDS -ge \$MAX_TIME ]; then\n      echo \"[cargo-safe] timeout attempt \$attempt\" >&2\n      kill \$PID 2>/dev/null; wait \$PID 2>/dev/null\n      kill -9 \$PID 2>/dev/null; wait \$PID 2>/dev/null\n      rm -f \"\$CARGO_HOME/.package-cache\"* 2>/dev/null\n      continue 2\n    fi\n    cat /scheme/sys/uname >/dev/null 2>/dev/null\n  done\n  wait \$PID\n  exit \$?\ndone\necho \"[cargo-safe] both attempts timed out\" >&2\nexit 124\n" > /tmp/cargo-build-safe && chmod +x /tmp/cargo-build-safe'

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

                        # ── Step 4e: rustc direct link (rustc -o binary, no cargo) ──
                        echo "--- Step 4e: rustc -o binary (direct link, no cargo) ---"
                        rm -f /tmp/abort.log
                        echo 'fn main() { println!("direct link works!"); }' > /tmp/direct_link.rs
                        # Full compile+link in one step — tests rustc's linker invocation
                        # Must pass -C linker=ld.lld explicitly (cargo config only applies through cargo)
                        rustc /tmp/direct_link.rs -o /tmp/direct_link_bin \
                          -C linker=/nix/system/profile/bin/ld.lld -C linker-flavor=ld.lld \
                          -C link-arg=-L/usr/lib/redox-sysroot/lib \
                          >/tmp/rustc-direct-link-stdout ^>/tmp/rustc-direct-link-stderr
                        let direct_link_exit = $?
                        echo "rustc -o binary exit: $direct_link_exit"
                        echo "rustc link stdout:"
                        cat /tmp/rustc-direct-link-stdout
                        echo "rustc link stderr:"
                        cat /tmp/rustc-direct-link-stderr
                        if test $direct_link_exit = 0
                          if exists -f /tmp/direct_link_bin
                            /tmp/direct_link_bin > /tmp/direct-link-run-out ^>/tmp/direct-link-run-err
                            let run_exit = $?
                            echo "Direct link binary exit: $run_exit"
                            echo "Output: $(cat /tmp/direct-link-run-out)"
                            echo "FUNC_TEST:rustc-direct-link:PASS"
                          else
                            echo "FUNC_TEST:rustc-direct-link:FAIL:binary not created"
                          end
                        else
                          # Check abort.log
                          if exists -f /tmp/abort.log
                            echo "abort.log:"
                            cat /tmp/abort.log
                          end
                          echo "FUNC_TEST:rustc-direct-link:FAIL:exit=$direct_link_exit"
                        end

                        # ── environ-diag: trace ld_so environ injection ──
                        echo "--- environ-diag: ld_so environ trace ---"

                        # Part A: compile a program that checks runtime env::var()
                        # This tests if the COMPILED binary can read env vars at runtime.
                        echo 'fn main() {' > /tmp/env_runtime.rs
                        echo '    eprintln!("=== runtime env dump ===");' >> /tmp/env_runtime.rs
                        echo '    for (k, v) in std::env::vars() {' >> /tmp/env_runtime.rs
                        echo '        if k.starts_with("DIAG") || k.starts_with("LD_") || k.starts_with("PATH") || k.starts_with("HOME") {' >> /tmp/env_runtime.rs
                        echo '            eprintln!("  {}={}", k, v);' >> /tmp/env_runtime.rs
                        echo '        }' >> /tmp/env_runtime.rs
                        echo '    }' >> /tmp/env_runtime.rs
                        echo '    eprintln!("  total env vars: {}", std::env::vars().count());' >> /tmp/env_runtime.rs
                        echo '    eprintln!("=== end runtime env ===");' >> /tmp/env_runtime.rs
                        echo '    let val = std::env::var("DIAG_TEST_VAR").unwrap_or("NOTFOUND".into());' >> /tmp/env_runtime.rs
                        echo '    println!("RUNTIME_DIAG_TEST_VAR={}", val);' >> /tmp/env_runtime.rs
                        echo '}' >> /tmp/env_runtime.rs

                        /nix/system/profile/bin/bash -c 'rustc /tmp/env_runtime.rs --edition 2021 -o /tmp/env_runtime_bin --crate-type bin -C linker=/nix/system/profile/bin/ld.lld -C linker-flavor=ld.lld -C link-arg=-L/usr/lib/redox-sysroot/lib 2>/tmp/env-runtime-stderr; echo "runtime-rustc-exit=$?"'
                        if exists -f /tmp/env_runtime_bin
                          /nix/system/profile/bin/bash -c 'DIAG_TEST_VAR=hello_runtime /tmp/env_runtime_bin >/tmp/env-runtime-out 2>/tmp/env-runtime-err'
                          echo "=== runtime env test ==="
                          cat /tmp/env-runtime-out
                          cat /tmp/env-runtime-err
                          echo "=== end runtime env test ==="
                        else
                          echo "runtime env test: compile failed"
                          cat /tmp/env-runtime-stderr
                        end

                        # Part B: compile-time env!() assertion test
                        # env!() FAILS compilation if the var is not set — no need to run binary
                        echo 'fn main() { println!("{}", env!("DIAG_TEST_VAR")); }' > /tmp/env_assert.rs

                        /nix/system/profile/bin/bash -c '
                          DIAG_TEST_VAR=hello_from_environ rustc /tmp/env_assert.rs --edition 2021 -o /tmp/env_assert_bin --crate-type bin -C linker=/nix/system/profile/bin/ld.lld -C linker-flavor=ld.lld -C link-arg=-L/usr/lib/redox-sysroot/lib 2>/tmp/env-assert-stderr
                          EXIT=$?
                          echo "env-assert-exit=$EXIT"
                          echo "=== env!() assertion stderr ==="
                          cat /tmp/env-assert-stderr
                          echo "=== end env!() stderr ==="
                          if [ "$EXIT" = "0" ]; then
                            echo "env!() compilation succeeded - var IS visible to rustc"
                            echo "FUNC_TEST:environ-diag:PASS"
                          else
                            echo "env!() compilation FAILED - var NOT visible to rustc"
                            echo "FUNC_TEST:environ-diag:FAIL:env-macro-failed"
                          fi
                        '

                        # Part C: option_env!() test (just for comparison)
                        echo 'fn main() {' > /tmp/env_diag.rs
                        echo '    match option_env!("DIAG_TEST_VAR") {' >> /tmp/env_diag.rs
                        echo '        Some(v) => println!("COMPILE_TIME_DIAG={}", v),' >> /tmp/env_diag.rs
                        echo '        None => println!("COMPILE_TIME_DIAG=NONE"),' >> /tmp/env_diag.rs
                        echo '    }' >> /tmp/env_diag.rs
                        echo '}' >> /tmp/env_diag.rs

                        /nix/system/profile/bin/bash -c 'DIAG_TEST_VAR=hello_from_environ rustc /tmp/env_diag.rs --edition 2021 -o /tmp/env_diag_bin --crate-type bin -C linker=/nix/system/profile/bin/ld.lld -C linker-flavor=ld.lld -C link-arg=-L/usr/lib/redox-sysroot/lib >/tmp/env-diag-stdout 2>/tmp/env-diag-stderr; echo "rustc-exit=$?"'

                        echo "=== ld_so environ-diag stderr ==="
                        cat /tmp/env-diag-stderr
                        echo "=== end stderr ==="

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

                        # Test: probe with --target x86_64-unknown-redox (what cargo actually sends)
                        echo "--- cargo probe with --target (the REAL probe cargo uses) ---"
                        rm -f /tmp/abort.log
                        echo "" | rustc - --crate-name ___ --print=file-names -C linker-flavor=ld.lld -C link-arg=-L/usr/lib/redox-sysroot/lib --target x86_64-unknown-redox --crate-type bin --crate-type rlib --crate-type dylib --crate-type cdylib --crate-type staticlib --crate-type proc-macro --print=sysroot --print=split-debuginfo --print=crate-name --print=cfg -Wwarnings > /tmp/cargo-probe-target-out ^>/tmp/cargo-probe-target-err
                        let probe_target_exit = $?
                        echo "cargo probe with --target exit: $probe_target_exit"
                        if test $probe_target_exit = 0
                          echo "FUNC_TEST:cargo-probe-target:PASS"
                          echo "probe-target output (first 200b):"
                          head -c 200 /tmp/cargo-probe-target-out
                        else
                          echo "FUNC_TEST:cargo-probe-target:FAIL:exit=$probe_target_exit"
                          echo "probe-target stderr:"
                          head -c 500 /tmp/cargo-probe-target-err
                          if exists -f /tmp/abort.log
                            echo "abort.log:"
                            cat /tmp/abort.log
                          end
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
                            # Use a background process + sleep to implement timeout
                            # This prevents the test from hanging forever
                            # NOTE: seq is not available on Redox; use bash brace expansion
                            /nix/system/profile/bin/bash -c '
                              cd /tmp/hello
                              export RUSTC=/tmp/rustc-spy2
                              cargo build >/tmp/cargo-spy2-stdout 2>/tmp/cargo-spy2-stderr &
                              CARGO_PID=$!
                              SECONDS=0
                              while kill -0 $CARGO_PID 2>/dev/null; do
                                if [ $SECONDS -ge 60 ]; then
                                  echo "spy2-exit=TIMEOUT"
                                  kill $CARGO_PID 2>/dev/null
                                  wait $CARGO_PID 2>/dev/null
                                  kill -9 $CARGO_PID 2>/dev/null
                                  exit 0
                                fi
                                cat /scheme/sys/uname >/dev/null 2>/dev/null
                              done
                              wait $CARGO_PID
                              echo "spy2-exit=$?"
                            ' > /tmp/cargo-spy2-out
                            cat /tmp/cargo-spy2-out
                            echo "=== cargo stdout ==="
                            if exists -f /tmp/cargo-spy2-stdout
                              head -c 1000 /tmp/cargo-spy2-stdout
                            end
                            echo "=== cargo stderr ==="
                            if exists -f /tmp/cargo-spy2-stderr
                              head -c 2000 /tmp/cargo-spy2-stderr
                            end
                            if exists -f /tmp/rustc-spy2.log
                              echo "=== spy2 log ==="
                              cat /tmp/rustc-spy2.log
                            end
                            # Check abort.log — this is the key diagnostic
                            echo "=== abort.log (from _exit(134) patch) ==="
                            if exists -f /tmp/abort.log
                              cat /tmp/abort.log
                              echo "(abort.log exists — rustc hit abort path)"
                            else
                              echo "(no abort.log — rustc did NOT hit abort)"
                            end
                          else
                            echo "spy2 link failed"
                          end
                        else
                          echo "spy2 compile failed"
                        end

                        # ── Cargo build test ──
                        # CWD injection in ld_so means rustc resolves relative paths directly.
                        # No rustc-abs wrapper needed.
                        echo "--- Setting up cargo project ---"
                        /nix/system/profile/bin/bash -c '
                          rm -rf /tmp/hello-direct
                          mkdir -p /tmp/hello-direct/src
                          printf "fn main() { println!(\"Hello from self-hosted Redox!\"); }\n" > /tmp/hello-direct/src/main.rs
                          printf "[package]\nname = \"hello\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" > /tmp/hello-direct/Cargo.toml
                          echo "Project created:"
                          ls -la /tmp/hello-direct/src/main.rs
                          cat /tmp/hello-direct/src/main.rs
                        '

                        # Quick diagnostic: does bash see the file with relative path?
                        echo "--- cat relative path diagnostic ---"
                        /nix/system/profile/bin/bash -c '
                          cd /tmp/hello-direct && echo "bash-pwd=$(pwd)" && cat src/main.rs
                        '

                        # Test: cargo build (direct rustc, no wrapper)
                        echo "--- Cargo build ---"
                        /nix/system/profile/bin/bash -c '
                          set -x
                          cd /tmp/hello-direct
                          rm -rf target
                          rm -f /tmp/abort.log /tmp/panic.log
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          export CARGO_HOME=/root/.cargo
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc
                          cargo build -vv >/tmp/cargo-abs-stdout 2>/tmp/cargo-abs-stderr &
                          CARGO_PID=$!
                          SECONDS=0
                          TMOUT=90
                          while kill -0 $CARGO_PID 2>/dev/null; do
                            if [ $SECONDS -ge $TMOUT ]; then
                              echo "TIMEOUT after ''${TMOUT}s"
                              kill $CARGO_PID 2>/dev/null
                              wait $CARGO_PID 2>/dev/null
                              kill -9 $CARGO_PID 2>/dev/null
                              echo "cargo-abs=TIMEOUT" > /tmp/cargo-abs-result
                              break
                            fi
                            cat /scheme/sys/uname >/dev/null 2>/dev/null
                          done
                          if ! kill -0 $CARGO_PID 2>/dev/null; then
                            wait $CARGO_PID
                            echo "cargo-abs=$?" > /tmp/cargo-abs-result
                          fi
                        '
                        echo "=== cargo-abs result ==="
                        cat /tmp/cargo-abs-result
                        echo "=== cargo-abs stdout ==="
                        if exists -f /tmp/cargo-abs-stdout
                          head -c 2000 /tmp/cargo-abs-stdout
                        end
                        echo "=== cargo-abs stderr ==="
                        if exists -f /tmp/cargo-abs-stderr
                          head -c 4000 /tmp/cargo-abs-stderr
                        end

                        # Check if the binary exists and runs
                        if exists -f /tmp/hello-direct/target/x86_64-unknown-redox/debug/hello
                          echo "FUNC_TEST:cargo-build:PASS"
                          let output = $(/tmp/hello-direct/target/x86_64-unknown-redox/debug/hello)
                          echo "Binary output: $output"
                        else
                          # Fall back to result from cargo
                          let cargo_abs_res = $(cat /tmp/cargo-abs-result)
                          echo "FUNC_TEST:cargo-build:FAIL:$cargo_abs_res"
                        end

                        # ── Direct cargo build (no RUSTC override — uses system rustc) ──
                        echo "--- Direct cargo build (no RUSTC override) ---"
                        /nix/system/profile/bin/bash -c '
                          set -x
                          rm -rf /tmp/hello-direct2
                          mkdir -p /tmp/hello-direct2/src
                          printf "fn main() { println!(\"Hello direct!\"); }\n" > /tmp/hello-direct2/src/main.rs
                          printf "[package]\nname = \"hello\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" > /tmp/hello-direct2/Cargo.toml
                          cd /tmp/hello-direct2
                          rm -f /tmp/abort.log /tmp/panic.log
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          export CARGO_HOME=/root/.cargo
                          export CARGO_INCREMENTAL=0
                          # Run cargo build in background with timeout using bash SECONDS
                          cargo build -vv >/tmp/cargo-direct-stdout 2>/tmp/cargo-direct-stderr &
                          CARGO_PID=$!
                          SECONDS=0
                          TMOUT=60
                          while kill -0 $CARGO_PID 2>/dev/null; do
                            if [ $SECONDS -ge $TMOUT ]; then
                              echo "TIMEOUT after ''${TMOUT}s"
                              kill $CARGO_PID 2>/dev/null
                              wait $CARGO_PID 2>/dev/null
                              kill -9 $CARGO_PID 2>/dev/null
                              echo "cargo-direct=TIMEOUT" > /tmp/cargo-direct-result
                              break
                            fi
                            # Busy-wait: no sleep/read -t on Redox (nanosleep hangs).
                            # Use /scheme/sys/uname reads as a ~5ms delay to avoid CPU spin.
                            cat /scheme/sys/uname >/dev/null 2>/dev/null
                          done
                          if ! kill -0 $CARGO_PID 2>/dev/null; then
                            wait $CARGO_PID
                            echo "cargo-direct=$?" > /tmp/cargo-direct-result
                          fi
                        '
                        echo "=== cargo-direct exit ==="
                        cat /tmp/cargo-direct-result
                        echo "=== cargo-direct stderr (first 2000b) ==="
                        if exists -f /tmp/cargo-direct-stderr
                          head -c 2000 /tmp/cargo-direct-stderr
                        end
                        let cargo_direct_res = $(cat /tmp/cargo-direct-result)
                        if test "$cargo_direct_res" = "cargo-direct=0"
                          echo "FUNC_TEST:cargo-direct-no-wrapper:PASS"
                        else
                          echo "FUNC_TEST:cargo-direct-no-wrapper:FAIL:$cargo_direct_res"
                        end
                          # ── Timeout diagnostic: try the exact rustc command from shell ──
                          echo "--- Timeout diagnostic: replicate cargo rustc cmd ---"
                          # Extract the rustc command from cargo -vv output
                        # ── Step 4f: subprocess fork tests ──
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

                        # Test: the built binary exists and runs (from the WRAPPED cargo build above)
                        if exists -f /tmp/hello-direct/target/x86_64-unknown-redox/debug/hello
                          echo "FUNC_TEST:binary-exists:PASS"
                          # Use bash to capture output — Ion $() is unreliable with absolute binary paths
                          /nix/system/profile/bin/bash -c '/tmp/hello-direct/target/x86_64-unknown-redox/debug/hello > /tmp/binary-output 2>&1; echo $? > /tmp/binary-exit'
                          let output = $(cat /tmp/binary-output)
                          if test "$output" = "Hello from self-hosted Redox!"
                            echo "FUNC_TEST:binary-runs:PASS"
                          else
                            echo "FUNC_TEST:binary-runs:FAIL:unexpected output: $output"
                          end
                        else
                          echo "FUNC_TEST:binary-exists:FAIL"
                          echo "FUNC_TEST:binary-runs:SKIP"
                        end

                        # ═══════════════════════════════════════════════════════════════
                        # Step 5: Real program — exercises std library beyond println
                        # ═══════════════════════════════════════════════════════════════
                        echo ""
                        echo "--- Step 5: Real program (std features) ---"

                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          # Fresh cargo home per test to avoid stale flock hangs
                          rm -rf /tmp/cargo-realtest
                          mkdir -p /tmp/cargo-realtest
                          cp /root/.cargo/config.toml /tmp/cargo-realtest/
                          export CARGO_HOME=/tmp/cargo-realtest
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc

                          rm -rf /tmp/realtest
                          mkdir -p /tmp/realtest/src

                          # A real program: HashMap, Vec, String, file I/O, formatting, iterators
                          cat > /tmp/realtest/src/main.rs << '"'"'RUSTEOF'"'"'
                    use std::collections::HashMap;
                    use std::fs;

                    fn fibonacci(n: u32) -> u64 {
                        let mut a: u64 = 0;
                        let mut b: u64 = 1;
                        for _ in 0..n {
                            let t = a + b;
                            a = b;
                            b = t;
                        }
                        a
                    }

                    fn word_count(text: &str) -> HashMap<String, usize> {
                        let mut counts = HashMap::new();
                        for word in text.split_whitespace() {
                            let w = word.to_lowercase();
                            *counts.entry(w).or_insert(0) += 1;
                        }
                        counts
                    }

                    fn main() {
                        // Test 1: Fibonacci computation
                        let fib20 = fibonacci(20);
                        assert_eq!(fib20, 6765, "fibonacci(20) wrong");

                        // Test 2: HashMap + iterators
                        let text = "the quick brown fox jumps over the lazy dog the fox";
                        let counts = word_count(text);
                        assert_eq!(counts.get("the"), Some(&3), "word count wrong");
                        assert_eq!(counts.get("fox"), Some(&2), "word count wrong");

                        // Test 3: Vec + sorting + collect
                        let mut nums: Vec<i32> = vec![5, 2, 8, 1, 9, 3];
                        nums.sort();
                        let sorted: String = nums.iter().map(|n| n.to_string()).collect::<Vec<_>>().join(",");
                        assert_eq!(sorted, "1,2,3,5,8,9", "sort wrong");

                        // Test 4: String formatting
                        let msg = format!("fib({})={}, words={}, sorted=[{}]", 20, fib20, counts.len(), sorted);
                        assert!(msg.contains("fib(20)=6765"), "format wrong");

                        // Test 5: File I/O
                        let test_data = "Hello from Redox self-hosting!\nLine 2\nLine 3\n";
                        fs::write("/tmp/realtest-output.txt", test_data).expect("write failed");
                        let read_back = fs::read_to_string("/tmp/realtest-output.txt").expect("read failed");
                        assert_eq!(read_back, test_data, "file roundtrip failed");

                        // Test 6: Env vars
                        let home = std::env::var("CARGO_HOME").unwrap_or_else(|_| "unknown".to_string());
                        assert!(!home.is_empty(), "CARGO_HOME empty");

                        // Test 7: Iterator chains
                        let sum: i64 = (1..=100).filter(|n| n % 2 == 0).map(|n| n * n).sum();
                        assert_eq!(sum, 171700, "iterator chain wrong");

                        // Test 8: Box, Option, Result
                        let boxed: Box<dyn std::fmt::Display> = Box::new(42);
                        let formatted = format!("{}", boxed);
                        assert_eq!(formatted, "42", "box display wrong");

                        let opt: Option<&str> = Some("hello");
                        let val = opt.map(|s| s.len()).unwrap_or(0);
                        assert_eq!(val, 5, "option wrong");

                        println!("REAL_PROGRAM_OK: {} tests passed, {}", 8, msg);
                    }
  RUSTEOF

                          cat > /tmp/realtest/Cargo.toml << '"'"'TOMLEOF'"'"'
                    [package]
                    name = "realtest"
                    version = "0.1.0"
                    edition = "2021"
  TOMLEOF

                          cd /tmp/realtest
                          rm -f /root/.cargo/.package-cache* /root/.cargo/.global-cache* 2>/dev/null
                          echo "[realtest] starting cargo build..."
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>/tmp/realtest-stderr
                          CARGO_EXIT=$?
                          echo "cargo-exit=$CARGO_EXIT" > /tmp/realtest-result

                          if [ $CARGO_EXIT -eq 0 ]; then
                            ./target/x86_64-unknown-redox/debug/realtest > /tmp/realtest-stdout 2>&1
                            echo "run-exit=$?" >> /tmp/realtest-result
                          fi
                        '

                        if exists -f /tmp/realtest-stdout
                          let real_out = $(cat /tmp/realtest-stdout)
                          echo "Real program output: $real_out"
                        end
                        if exists -f /tmp/realtest-stderr
                          echo "Real program cargo stderr (first 1000b):"
                          head -c 1000 /tmp/realtest-stderr
                        end

                        let real_result = $(cat /tmp/realtest-result 2>/dev/null)
                        # Check for REAL_PROGRAM_OK in output
                        /nix/system/profile/bin/bash -c 'grep -q "REAL_PROGRAM_OK" /tmp/realtest-stdout 2>/dev/null'
                        if test $? = 0
                          echo "FUNC_TEST:real-program:PASS"
                        else
                          echo "FUNC_TEST:real-program:FAIL:$real_result"
                        end

                        # ═══════════════════════════════════════════════════════════════
                        # Step 6: Multi-file project — tests module system, use/mod
                        # ═══════════════════════════════════════════════════════════════
                        echo ""
                        echo "--- Step 6: Multi-file project ---"

                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          # Use a FRESH cargo home (copy config, avoid stale locks)
                          rm -rf /tmp/cargo-multifile
                          mkdir -p /tmp/cargo-multifile
                          cp /root/.cargo/config.toml /tmp/cargo-multifile/
                          export CARGO_HOME=/tmp/cargo-multifile
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc

                          rm -rf /tmp/multifile
                          mkdir -p /tmp/multifile/src

                          # Module: lib.rs with a public module
                          cat > /tmp/multifile/src/lib.rs << '"'"'LIBEOF'"'"'
                    pub mod math {
                        pub fn gcd(mut a: u64, mut b: u64) -> u64 {
                            while b != 0 {
                                let t = b;
                                b = a % b;
                                a = t;
                            }
                            a
                        }

                        pub fn lcm(a: u64, b: u64) -> u64 {
                            a / gcd(a, b) * b
                        }

                        #[cfg(test)]
                        mod tests {
                            use super::*;

                            #[test]
                            fn test_gcd() {
                                assert_eq!(gcd(12, 8), 4);
                                assert_eq!(gcd(100, 75), 25);
                                assert_eq!(gcd(7, 13), 1);
                            }

                            #[test]
                            fn test_lcm() {
                                assert_eq!(lcm(4, 6), 12);
                                assert_eq!(lcm(3, 5), 15);
                            }
                        }
                    }

                    pub mod text {
                        pub fn caesar_cipher(input: &str, shift: u8) -> String {
                            input.chars().map(|c| {
                                if c.is_ascii_lowercase() {
                                    (b'"'"'a'"'"' + (c as u8 - b'"'"'a'"'"' + shift) % 26) as char
                                } else if c.is_ascii_uppercase() {
                                    (b'"'"'A'"'"' + (c as u8 - b'"'"'A'"'"' + shift) % 26) as char
                                } else {
                                    c
                                }
                            }).collect()
                        }

                        pub fn reverse_words(input: &str) -> String {
                            input.split_whitespace()
                                .rev()
                                .collect::<Vec<_>>()
                                .join(" ")
                        }
                    }
  LIBEOF

                          cat > /tmp/multifile/src/main.rs << '"'"'MAINEOF'"'"'
                    use multifile::math::{gcd, lcm};
                    use multifile::text::{caesar_cipher, reverse_words};

                    fn main() {
                        // Module: math
                        assert_eq!(gcd(12, 8), 4);
                        assert_eq!(lcm(4, 6), 12);

                        // Module: text
                        let encrypted = caesar_cipher("Hello World", 3);
                        assert_eq!(encrypted, "Khoor Zruog");
                        let decrypted = caesar_cipher(&encrypted, 23); // 26-3 = 23
                        assert_eq!(decrypted, "Hello World");

                        let reversed = reverse_words("one two three four");
                        assert_eq!(reversed, "four three two one");

                        println!("MULTIFILE_OK: math+text modules working");
                    }
  MAINEOF

                          cat > /tmp/multifile/Cargo.toml << '"'"'TOMLEOF'"'"'
                    [package]
                    name = "multifile"
                    version = "0.1.0"
                    edition = "2021"

                    [[bin]]
                    name = "multifile"
                    path = "src/main.rs"

                    [lib]
                    name = "multifile"
                    path = "src/lib.rs"
  TOMLEOF

                          cd /tmp/multifile
                          echo "[multifile] starting cargo build (offline)..."
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>/tmp/multifile-stderr
                          CARGO_EXIT=$?

                          if [ $CARGO_EXIT -eq 0 ]; then
                            ./target/x86_64-unknown-redox/debug/multifile > /tmp/multifile-stdout 2>&1
                            echo "run-exit=$?" >> /tmp/multifile-result
                          fi
                          echo "cargo-exit=$CARGO_EXIT" > /tmp/multifile-result
                        '

                        if exists -f /tmp/multifile-stdout
                          let multi_out = $(cat /tmp/multifile-stdout)
                          echo "Multi-file output: $multi_out"
                        end

                        /nix/system/profile/bin/bash -c 'grep -q "MULTIFILE_OK" /tmp/multifile-stdout 2>/dev/null'
                        if test $? = 0
                          echo "FUNC_TEST:multifile-build:PASS"
                        else
                          if exists -f /tmp/multifile-stderr
                            echo "Multi-file stderr:"
                            head -c 1000 /tmp/multifile-stderr
                          end
                          let multi_res = $(cat /tmp/multifile-result 2>/dev/null)
                          echo "FUNC_TEST:multifile-build:FAIL:$multi_res"
                        end


                        # ═══════════════════════════════════════════════════════════════
                        # Step 7: Manual build script (bypass cargo, use rustc directly)
                        # Tests whether sequential rustc invocations work when a build
                        # script binary runs in between. Isolates the crash from cargo.
                        # ═══════════════════════════════════════════════════════════════
                        echo ""
                        echo "--- Step 7: Manual build script (rustc-only, no cargo) ---"

                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"

                          rm -rf /tmp/buildscript
                          mkdir -p /tmp/buildscript/src /tmp/buildscript/out

                          cat > /tmp/buildscript/build.rs << BUILDEOF
                use std::env;
                use std::fs;
                use std::path::Path;
                fn main() {
                    let out_dir = env::var("OUT_DIR").unwrap_or_else(|_| "/tmp/buildscript/out".to_string());
                    let dest_path = Path::new(&out_dir).join("generated.rs");
                    let code = "pub const BUILD_TARGET: &str = \"x86_64-unknown-redox\";\npub const GENERATED_VALUE: u64 = 42 * 137;\n";
                    fs::write(&dest_path, code).expect("write failed");
                    eprintln!("build.rs: wrote generated.rs");
                }
  BUILDEOF

                          cat > /tmp/buildscript/src/main.rs << MAINEOF
                include!("/tmp/buildscript/out/generated.rs");
                fn main() {
                    assert_eq!(GENERATED_VALUE, 42 * 137);
                    assert_eq!(BUILD_TARGET, "x86_64-unknown-redox");
                    println!("BUILDSCRIPT_OK: target={}, val={}", BUILD_TARGET, GENERATED_VALUE);
                }
  MAINEOF

                          echo "[bs] Step 1: compile build.rs..."
                          rustc --edition=2021 /tmp/buildscript/build.rs \
                            -o /tmp/buildscript/build-script-bin \
                            --target x86_64-unknown-redox \
                            -C linker=/nix/system/profile/bin/cc \
                            -C link-arg=-L/usr/lib/redox-sysroot/lib \
                            2>/tmp/buildscript-step1.log
                          STEP1=$?
                          echo "[bs] Step 1 exit: $STEP1"
                          if [ $STEP1 -ne 0 ]; then cat /tmp/buildscript-step1.log; fi

                          STEP2=99
                          if [ $STEP1 -eq 0 ]; then
                            echo "[bs] Step 2: run build script..."
                            OUT_DIR=/tmp/buildscript/out /tmp/buildscript/build-script-bin 2>/tmp/buildscript-step2.log
                            STEP2=$?
                            echo "[bs] Step 2 exit: $STEP2"
                            if [ $STEP2 -ne 0 ]; then cat /tmp/buildscript-step2.log; fi
                          fi

                          STEP3=99
                          if [ $STEP2 -eq 0 ] && [ -f /tmp/buildscript/out/generated.rs ]; then
                            echo "[bs] generated.rs:"
                            cat /tmp/buildscript/out/generated.rs
                            echo "[bs] Step 3: compile src/main.rs (second rustc)..."
                            rustc --edition=2021 /tmp/buildscript/src/main.rs \
                              -o /tmp/buildscript/main-bin \
                              --target x86_64-unknown-redox \
                              -C linker=/nix/system/profile/bin/cc \
                              -C link-arg=-L/usr/lib/redox-sysroot/lib \
                              2>/tmp/buildscript-step3.log
                            STEP3=$?
                            echo "[bs] Step 3 exit: $STEP3"
                            if [ $STEP3 -ne 0 ]; then cat /tmp/buildscript-step3.log; fi
                          fi

                          if [ $STEP3 -eq 0 ]; then
                            echo "[bs] Step 4: run binary..."
                            /tmp/buildscript/main-bin > /tmp/buildscript-stdout 2>&1
                            echo "run-exit=$?" > /tmp/buildscript-result
                          else
                            echo "steps=$STEP1/$STEP2/$STEP3" > /tmp/buildscript-result
                          fi
                        '

                        if exists -f /tmp/buildscript-stdout
                          let bs_out = $(cat /tmp/buildscript-stdout)
                          echo "Build script output: $bs_out"
                        end

                        /nix/system/profile/bin/bash -c 'grep -q "BUILDSCRIPT_OK" /tmp/buildscript-stdout 2>/dev/null'
                        if test $? = 0
                          echo "FUNC_TEST:buildscript:PASS"
                        else
                          if exists -f /tmp/buildscript-result
                            let bs_res = $(cat /tmp/buildscript-result)
                            echo "FUNC_TEST:buildscript:FAIL:$bs_res"
                          else
                            echo "FUNC_TEST:buildscript:FAIL:no-result"
                          end
                        end

                        # ═══════════════════════════════════════════════════════════════
                        # Step 8: Practical tool — mini-grep built and tested on Redox
                        # A real CLI tool: args, file I/O, pattern matching, error handling
                        # ═══════════════════════════════════════════════════════════════
                        echo ""
                        echo "--- Step 8: Mini-grep tool ---"

                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          rm -rf /tmp/cargo-minigrep
                          mkdir -p /tmp/cargo-minigrep
                          cp /root/.cargo/config.toml /tmp/cargo-minigrep/
                          export CARGO_HOME=/tmp/cargo-minigrep
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc

                          rm -rf /tmp/minigrep
                          mkdir -p /tmp/minigrep/src

                          echo "[minigrep] writing source..."
                          printf "%s\n" \
                            "use std::env;" \
                            "use std::fs;" \
                            "use std::io::{self, BufRead, Write};" \
                            "use std::process;" \
                            "" \
                            "fn matches_pattern(line: &str, pattern: &str, case_insensitive: bool) -> bool {" \
                            "    if case_insensitive {" \
                            "        line.to_lowercase().contains(&pattern.to_lowercase())" \
                            "    } else {" \
                            "        line.contains(pattern)" \
                            "    }" \
                            "}" \
                            "" \
                            "fn search_file(path: &str, pattern: &str, case_insensitive: bool," \
                            "               show_line_nums: bool) -> io::Result<Vec<String>> {" \
                            "    let content = fs::read_to_string(path)?;" \
                            "    let mut results = Vec::new();" \
                            "    for (i, line) in content.lines().enumerate() {" \
                            "        if matches_pattern(line, pattern, case_insensitive) {" \
                            "            if show_line_nums {" \
                            "                results.push(format!(\"{}:{}:{}\", path, i + 1, line));" \
                            "            } else {" \
                            "                results.push(format!(\"{}:{}\", path, line));" \
                            "            }" \
                            "        }" \
                            "    }" \
                            "    Ok(results)" \
                            "}" \
                            "" \
                            "fn main() {" \
                            "    let args: Vec<String> = env::args().collect();" \
                            "    if args.len() < 3 {" \
                            "        eprintln!(\"Usage: {} [-i] [-n] <pattern> <file>...\", args[0]);" \
                            "        process::exit(1);" \
                            "    }" \
                            "" \
                            "    let mut case_insensitive = false;" \
                            "    let mut show_line_nums = false;" \
                            "    let mut positional = Vec::new();" \
                            "" \
                            "    for arg in &args[1..] {" \
                            "        match arg.as_str() {" \
                            "            \"-i\" => case_insensitive = true," \
                            "            \"-n\" => show_line_nums = true," \
                            "            _ => positional.push(arg.as_str())," \
                            "        }" \
                            "    }" \
                            "" \
                            "    if positional.len() < 2 {" \
                            "        eprintln!(\"Need pattern and at least one file\");" \
                            "        process::exit(1);" \
                            "    }" \
                            "" \
                            "    let pattern = positional[0];" \
                            "    let mut found = false;" \
                            "    let stdout = io::stdout();" \
                            "    let mut out = stdout.lock();" \
                            "" \
                            "    for file in &positional[1..] {" \
                            "        match search_file(file, pattern, case_insensitive, show_line_nums) {" \
                            "            Ok(matches) => {" \
                            "                for m in &matches {" \
                            "                    let _ = writeln!(out, \"{}\", m);" \
                            "                    found = true;" \
                            "                }" \
                            "            }" \
                            "            Err(e) => eprintln!(\"minigrep: {}: {}\", file, e)," \
                            "        }" \
                            "    }" \
                            "" \
                            "    if !found { process::exit(1); }" \
                            "}" \
                            > /tmp/minigrep/src/main.rs

                          printf "%s\n" \
                            "[package]" \
                            "name = \"minigrep\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            > /tmp/minigrep/Cargo.toml

                          # Create test data
                          printf "%s\n" \
                            "Hello World" \
                            "hello redox" \
                            "Rust on Redox OS" \
                            "self-hosted compilation" \
                            "HELLO AGAIN" \
                            "the quick brown fox" \
                            > /tmp/minigrep-testdata.txt

                          cd /tmp/minigrep
                          rm -f /root/.cargo/.package-cache* /root/.cargo/.global-cache* 2>/dev/null
                          echo "[minigrep] cargo build..."
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>/tmp/minigrep-stderr
                          MG_EXIT=$?
                          echo "[minigrep] cargo exit: $MG_EXIT"

                          if [ $MG_EXIT -eq 0 ]; then
                            BIN=./target/x86_64-unknown-redox/debug/minigrep
                            PASS=0
                            FAIL=0

                            # Test 1: basic pattern match
                            OUT=$($BIN "Redox" /tmp/minigrep-testdata.txt)
                            if echo "$OUT" | grep -q "Rust on Redox OS"; then
                              PASS=$((PASS+1))
                            else
                              echo "FAIL test1: $OUT"
                              FAIL=$((FAIL+1))
                            fi

                            # Test 2: case-insensitive
                            OUT=$($BIN -i "hello" /tmp/minigrep-testdata.txt)
                            LINES=$(echo "$OUT" | wc -l)
                            if [ "$LINES" -ge 3 ]; then
                              PASS=$((PASS+1))
                            else
                              echo "FAIL test2: lines=$LINES"
                              FAIL=$((FAIL+1))
                            fi

                            # Test 3: line numbers
                            OUT=$($BIN -n "fox" /tmp/minigrep-testdata.txt)
                            if echo "$OUT" | grep -q ":6:"; then
                              PASS=$((PASS+1))
                            else
                              echo "FAIL test3: $OUT"
                              FAIL=$((FAIL+1))
                            fi

                            # Test 4: no match returns exit 1
                            $BIN "NONEXISTENT_PATTERN" /tmp/minigrep-testdata.txt > /dev/null 2>&1
                            if [ $? -eq 1 ]; then
                              PASS=$((PASS+1))
                            else
                              echo "FAIL test4: expected exit 1"
                              FAIL=$((FAIL+1))
                            fi

                            # Test 5: missing file error
                            OUT=$($BIN "test" /tmp/nonexistent 2>&1)
                            # Redox grep does not support \| alternation — check each pattern
                            if echo "$OUT" | grep -qi "error"; then
                              PASS=$((PASS+1))
                            else
                              echo "FAIL test5: $OUT"
                              FAIL=$((FAIL+1))
                            fi

                            echo "MINIGREP_RESULT: $PASS passed, $FAIL failed" > /tmp/minigrep-stdout
                          fi
                        '

                        if exists -f /tmp/minigrep-stdout
                          let mg_out = $(cat /tmp/minigrep-stdout)
                          echo "Mini-grep: $mg_out"
                        end
                        if exists -f /tmp/minigrep-stderr
                          echo "Mini-grep stderr (tail):"
                          /nix/system/profile/bin/bash -c 'tail -5 /tmp/minigrep-stderr 2>/dev/null'
                        end

                        /nix/system/profile/bin/bash -c 'grep -q "0 failed" /tmp/minigrep-stdout 2>/dev/null'
                        if test $? = 0
                          echo "FUNC_TEST:minigrep:PASS"
                        else
                          let mg_res = $(cat /tmp/minigrep-stdout 2>/dev/null)
                          echo "FUNC_TEST:minigrep:FAIL:$mg_res"
                        end

                        # ═══════════════════════════════════════════════════════════════
                        # Step 9: Fork+exec crash isolation
                        # Test: does rustc compilation (not just -vV) work from a subprocess?
                        # Previous finding: rustc -vV works, but compilation crashes.
                        # ═══════════════════════════════════════════════════════════════
                        echo ""
                        echo "--- Step 9: Fork+exec + compilation test ---"

                        # Bash isolation test: what combination of rustc invocations crashes?
                        # Finding so far: A(-vV) and B(--emit=obj) work, C(full link) hangs

                        # Test 9a: Direct full compile+link WITH linker flags
                        # (cargo passes these; without them rustc uses a default linker that
                        # might not exist or hang trying to find it)
                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          LFLAGS="-C linker=/nix/system/profile/bin/cc -C link-arg=-L/usr/lib/redox-sysroot/lib"
                          echo "fn main() {}" > /tmp/fork-test-9a.rs
                          echo "[9a] full compile+link with linker flags..."
                          rustc $LFLAGS /tmp/fork-test-9a.rs -o /tmp/fork-test-9a-bin 2>/tmp/fork-test-9a-err
                          echo "[9a] exit: $?"
                          if [ -f /tmp/fork-test-9a-bin ]; then
                            /tmp/fork-test-9a-bin
                            echo "[9a] run exit: $?"
                          else
                            echo "[9a] NO BINARY produced"
                            echo "[9a] stderr:"
                            cat /tmp/fork-test-9a-err 2>/dev/null
                          fi
                        '

                        # Test 9b: Two sequential full compiles
                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          LFLAGS="-C linker=/nix/system/profile/bin/cc -C link-arg=-L/usr/lib/redox-sysroot/lib"
                          echo "fn main() { println!(\"alpha\"); }" > /tmp/fork-test-9b1.rs
                          echo "fn main() { println!(\"beta\"); }" > /tmp/fork-test-9b2.rs
                          echo "[9b] first compile+link..."
                          rustc $LFLAGS /tmp/fork-test-9b1.rs -o /tmp/fork-test-9b1-bin 2>/dev/null
                          echo "[9b] first exit: $?"
                          echo "[9b] second compile+link..."
                          rustc $LFLAGS /tmp/fork-test-9b2.rs -o /tmp/fork-test-9b2-bin 2>/dev/null
                          echo "[9b] second exit: $?"
                          if [ -f /tmp/fork-test-9b1-bin ]; then
                            OUT=$(/tmp/fork-test-9b1-bin)
                            echo "[9b] first output: $OUT"
                          fi
                          if [ -f /tmp/fork-test-9b2-bin ]; then
                            OUT=$(/tmp/fork-test-9b2-bin)
                            echo "[9b] second output: $OUT"
                          fi
                        '

                        # ═══════════════════════════════════════════════════════════════
                        # Step 10: Cargo build WITH build.rs (the holy grail!)
                        # Previous crashes were caused by missing linker flags when rustc
                        # was invoked directly. Through cargo, the flags come from config.toml.
                        # This should work now!
                        # ═══════════════════════════════════════════════════════════════
                        echo ""
                        echo "--- Step 10: Cargo build with build.rs ---"


                        /nix/system/profile/bin/bash -c '
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          rm -rf /tmp/cargo-buildrs
                          mkdir -p /tmp/cargo-buildrs
                          cp /root/.cargo/config.toml /tmp/cargo-buildrs/
                          export CARGO_HOME=/tmp/cargo-buildrs
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc
                          rm -f /root/.cargo/.package-cache* 2>/dev/null

                          rm -rf /tmp/buildrs-test
                          mkdir -p /tmp/buildrs-test/src

                          printf "%s\n" \
                            "fn main() {" \
                            "    println!(\"cargo:rustc-cfg=has_buildscript\");" \
                            "    let target = std::env::var(\"TARGET\").unwrap_or_default();" \
                            "    println!(\"cargo:rustc-env=BUILD_TARGET={}\", target);" \
                            "}" \
                            > /tmp/buildrs-test/build.rs

                          printf "%s\n" \
                            "fn main() {" \
                            "    #[cfg(has_buildscript)]" \
                            "    {" \
                            "        // Use option_env! to avoid compile-time failure if env propagation" \
                            "        // is broken (Redox exec() may not pass cargo:rustc-env vars)." \
                            "        // Also check runtime env for comparison." \
                            "        let compile_env = option_env!(\"BUILD_TARGET\");" \
                            "        let runtime_env = std::env::var(\"BUILD_TARGET\").ok();" \
                            "        match compile_env {" \
                            "            Some(t) => println!(\"BUILDRS_OK: target={}\", t)," \
                            "            None => println!(\"BUILDRS_OK: cfg=yes,env=missing,runtime={:?}\", runtime_env)," \
                            "        }" \
                            "    }" \
                            "    #[cfg(not(has_buildscript))]" \
                            "    {" \
                            "        println!(\"BUILDRS_FAIL: cfg not set\");" \
                            "    }" \
                            "}" \
                            > /tmp/buildrs-test/src/main.rs

                          printf "%s\n" \
                            "[package]" \
                            "name = \"buildrs-test\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            > /tmp/buildrs-test/Cargo.toml

                          cd /tmp/buildrs-test
                          echo "[buildrs] starting cargo build with build.rs..."
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe -vv 2>/tmp/buildrs-stderr
                          CARGO_EXIT=$?
                          echo "[buildrs] cargo exit code: $CARGO_EXIT"
                          echo "cargo-exit=$CARGO_EXIT" > /tmp/buildrs-result
                          echo "[buildrs] stderr size: $(wc -c < /tmp/buildrs-stderr 2>/dev/null || echo 0)"

                          if [ $CARGO_EXIT -eq 0 ]; then
                            BIN=./target/x86_64-unknown-redox/debug/buildrs-test
                            if [ -f "$BIN" ]; then
                              echo "[buildrs] binary found, running..."
                              $BIN > /tmp/buildrs-stdout 2>/tmp/buildrs-run-err
                              echo "run-exit=$?" >> /tmp/buildrs-result
                            else
                              echo "[buildrs] no binary at $BIN"
                              echo "no-binary" >> /tmp/buildrs-result
                              ls -la ./target/x86_64-unknown-redox/debug/ 2>/dev/null || echo "[buildrs] debug dir missing"
                            fi
                          else
                            echo "[buildrs] cargo failed, showing stderr..."
                            cat /tmp/buildrs-stderr 2>/dev/null | head -50
                            echo "[buildrs] checking for target dir..."
                            ls ./target/x86_64-unknown-redox/debug/*.d 2>/dev/null | head -5 || echo "[buildrs] no .d files"
                          fi
                        '

                        if exists -f /tmp/buildrs-stdout
                          let buildrs_out = $(cat /tmp/buildrs-stdout)
                          echo "Build.rs output: $buildrs_out"
                        end

                        /nix/system/profile/bin/bash -c 'grep -q "BUILDRS_OK" /tmp/buildrs-stdout 2>/dev/null'
                        if test $? = 0
                          /nix/system/profile/bin/bash -c 'cat /tmp/buildrs-stdout'
                          echo "FUNC_TEST:cargo-buildrs:PASS"
                        else
                          if exists -f /tmp/buildrs-stderr
                            echo "=== buildrs stderr (last 4KB) ==="
                            /nix/system/profile/bin/bash -c 'tail -c 4096 /tmp/buildrs-stderr 2>/dev/null'
                            echo "=== end buildrs stderr ==="
                          end
                          let buildrs_res = $(cat /tmp/buildrs-result 2>/dev/null)
                          echo "FUNC_TEST:cargo-buildrs:FAIL:$buildrs_res"
                        end

                        # ── Test: env!("CARGO_PKG_NAME") propagation ────────────
                        # Tests whether CARGO_PKG_NAME reaches rustc's env!() macro
                        # via DSO environ propagation. Broken environ was the root
                        # cause of ring build failures.
                        echo ""
                        echo "--- env-pkg-name: env!(CARGO_PKG_NAME) propagation ---"
                        /nix/system/profile/bin/bash -c '
                          rm -rf /tmp/env-pkg-test
                          mkdir -p /tmp/env-pkg-test/src

                          cat > /tmp/env-pkg-test/Cargo.toml << TOMLEOF
    [package]
    name = "envpkgtest"
    version = "0.1.0"
    edition = "2021"
  TOMLEOF

                          cat > /tmp/env-pkg-test/src/main.rs << RSEOF
    fn main() {
        // env!() is resolved at compile time by rustc.
        // Both CARGO_PKG_NAME and LD_LIBRARY_PATH reach rustc via DSO environ propagation.
        let name = env!("CARGO_PKG_NAME");
        let version = env!("CARGO_PKG_VERSION");
        // option_env! returns None if the var is not in rustc compile-time env
        let ld_lib = option_env!("LD_LIBRARY_PATH");
        let cargo_home = option_env!("CARGO_HOME");
        println!("ENV_PKG_OK: name={} version={}", name, version);
        println!("ENV_PROPAGATION: LD_LIBRARY_PATH={:?} CARGO_HOME={:?}", ld_lib, cargo_home);
    }
  RSEOF

                          cd /tmp/env-pkg-test
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>/tmp/env-pkg-stderr
                          CARGO_EXIT=$?
                          if [ $CARGO_EXIT -eq 0 ]; then
                            BIN=./target/x86_64-unknown-redox/debug/envpkgtest
                            if [ -f "$BIN" ]; then
                              OUTPUT=$($BIN 2>&1)
                              echo "$OUTPUT"
                              # Check both: env!() works AND process env propagation
                              if echo "$OUTPUT" | grep -q "ENV_PKG_OK"; then
                                echo "FUNC_TEST:env-pkg-name:PASS"
                                # Also report whether environ propagated (for diagnostics)
                                # Use bash case instead of grep -q (Redox grep misparses
                                # patterns containing = as invalid parameters)
                                case "$OUTPUT" in
                                  *"LD_LIBRARY_PATH=Some"*)
                                    echo "FUNC_TEST:env-propagation-simple:PASS"
                                    ;;
                                  *)
                                    echo "FUNC_TEST:env-propagation-simple:FAIL:environ not propagated"
                                    echo "  (env!() compiled but LD_LIBRARY_PATH not visible — DSO environ broken)"
                                    ;;
                                esac
                              else
                                echo "FUNC_TEST:env-pkg-name:FAIL:compile-fail"
                                echo "FUNC_TEST:env-propagation-simple:FAIL:env!() failed"
                              fi
                            else
                              echo "FUNC_TEST:env-pkg-name:FAIL:no-binary"
                              echo "FUNC_TEST:env-propagation-simple:FAIL:no-binary"
                            fi
                          else
                            echo "FUNC_TEST:env-pkg-name:FAIL:cargo-exit=$CARGO_EXIT"
                            echo "FUNC_TEST:env-propagation-simple:FAIL:cargo-exit=$CARGO_EXIT"
                            head -c 2000 /tmp/env-pkg-stderr 2>/dev/null
                          fi
                          rm -rf /tmp/env-pkg-test
                        '

                        # ── Test: env!("CARGO_PKG_NAME") after heavy-fork build.rs ──
                        # Simulates ring's build pattern: build.rs that fork+exec's
                        # cc/clang many times, then the lib target uses env!().
                        # This isolates whether fork activity in build.rs breaks
                        # env propagation for subsequent rustc invocations.
                        echo ""
                        echo "--- env-heavy-fork: env!() after build.rs fork storm ---"
                        /nix/system/profile/bin/bash -c '
                          rm -rf /tmp/heavyfork
                          mkdir -p /tmp/heavyfork/src

                          cat > /tmp/heavyfork/Cargo.toml << TOMLEOF
    [package]
    name = "heavyfork"
    version = "0.1.0"
    edition = "2021"
  TOMLEOF

                          # build.rs that dumps env AND forks clang 20 times
                          cat > /tmp/heavyfork/build.rs << RSEOF
    use std::process::Command;
    fn main() {
        // Dump env vars visible to build.rs (process environ)
        eprintln!("=== BUILD.RS ENVIRON DUMP ===");
        let mut count = 0;
        for (k, v) in std::env::vars() {
            if k.starts_with("CARGO") || k.starts_with("LD_") || k == "PATH"
                || k == "HOME" || k == "RUSTC" || k == "OUT_DIR" {
                eprintln!("  ENV: {}={}", k, v);
            }
            count += 1;
        }
        eprintln!("  TOTAL env vars: {}", count);
        eprintln!("=== END ENVIRON DUMP ===");

        // Fork+exec clang 20 times (simulating ring build.rs)
        for i in 0..20 {
            let status = Command::new("/nix/system/profile/bin/clang")
                .args(&["--version"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
            match status {
                Ok(s) => eprintln!("build.rs: clang fork {} exit={}", i, s),
                Err(e) => eprintln!("build.rs: clang fork {} err={}", i, e),
            }
        }
        // Also emit a cargo:rustc-env to test both paths
        println!("cargo:rustc-env=BUILD_FORKS=20");
    }
  RSEOF

                          # Library with env!("CARGO_PKG_NAME") — same pattern as ring
                          cat > /tmp/heavyfork/src/lib.rs << RSEOF
    // This is what ring does: use env!("CARGO_PKG_NAME") for symbol prefixing
    pub const PKG_NAME: &str = env!("CARGO_PKG_NAME");
    pub const PKG_VERSION: &str = env!("CARGO_PKG_VERSION");
    // Also check cargo:rustc-env from build.rs
    pub const BUILD_FORKS: &str = env!("BUILD_FORKS");
    // Check environ propagation survives heavy fork load (DSO environ stress test)
    pub const LD_LIB: Option<&str> = option_env!("LD_LIBRARY_PATH");
    pub const CARGO_HOME_ENV: Option<&str> = option_env!("CARGO_HOME");
  RSEOF

                          cat > /tmp/heavyfork/src/main.rs << RSEOF
    fn main() {
        println!("HEAVY_FORK_OK: name={} version={} forks={}",
            heavyfork::PKG_NAME,
            heavyfork::PKG_VERSION,
            heavyfork::BUILD_FORKS);
        println!("ENV_PROPAGATION: LD_LIBRARY_PATH={:?} CARGO_HOME={:?}",
            heavyfork::LD_LIB,
            heavyfork::CARGO_HOME_ENV);
    }
  RSEOF

                          cd /tmp/heavyfork
                          echo "[heavyfork] starting cargo build..."
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe -vv 2>/tmp/heavyfork-stderr
                          CARGO_EXIT=$?
                          echo "[heavyfork] cargo exit=$CARGO_EXIT"

                          # Show build.rs environ dump from stderr
                          if grep -q "BUILD.RS ENVIRON DUMP" /tmp/heavyfork-stderr 2>/dev/null; then
                            echo "=== build.rs environ dump ==="
                            grep -A100 "BUILD.RS ENVIRON DUMP" /tmp/heavyfork-stderr | head -50
                            echo "=== end ==="
                          fi

                          if [ $CARGO_EXIT -eq 0 ]; then
                            BIN=./target/x86_64-unknown-redox/debug/heavyfork
                            if [ -f "$BIN" ]; then
                              OUTPUT=$($BIN 2>&1)
                              echo "$OUTPUT"
                              if echo "$OUTPUT" | grep -q "HEAVY_FORK_OK"; then
                                echo "FUNC_TEST:env-heavy-fork:PASS"
                                # Check if env propagation survived the fork storm
                                # Use bash case instead of grep -q (Redox grep misparses
                                # patterns containing = as invalid parameters)
                                case "$OUTPUT" in
                                  *"LD_LIBRARY_PATH=Some"*)
                                    echo "FUNC_TEST:env-propagation-heavy:PASS"
                                    ;;
                                  *)
                                    echo "FUNC_TEST:env-propagation-heavy:FAIL:environ lost after fork storm"
                                    ;;
                                esac
                              else
                                echo "FUNC_TEST:env-heavy-fork:FAIL:compile-fail"
                                echo "FUNC_TEST:env-propagation-heavy:FAIL:env!() failed"
                              fi
                            else
                              echo "FUNC_TEST:env-heavy-fork:FAIL:no-binary"
                              echo "FUNC_TEST:env-propagation-heavy:FAIL:no-binary"
                            fi
                          else
                            echo "FUNC_TEST:env-heavy-fork:FAIL:cargo-exit=$CARGO_EXIT"
                            echo "FUNC_TEST:env-propagation-heavy:FAIL:cargo-exit=$CARGO_EXIT"
                            # Show last errors (looking for "not defined at compile time")
                            echo "=== heavyfork stderr ==="
                            head -c 4000 /tmp/heavyfork-stderr 2>/dev/null
                            echo "=== end ==="
                          fi
                          rm -rf /tmp/heavyfork
                        '

                        # ══════════════════════════════════════════════════════════
                        # Phase 3: Crate Dependencies
                        # ══════════════════════════════════════════════════════════

                        # ── Test: Path dependency (local subcrate) ──────────────
                        # Tests multi-crate workspace-like compilation with a local
                        # library crate used as a path dependency.
                        echo ""
                        echo "--- cargo-path-dep: local path dependency ---"
                        /nix/system/profile/bin/bash -c '
                          # Build pathdep project
                          rm -rf /tmp/pathdep
                          mkdir -p /tmp/pathdep/src /tmp/pathdep/mylib/src

                          # Library crate
                          printf "%s\n" \
                            "[package]" \
                            "name = \"mylib\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            > /tmp/pathdep/mylib/Cargo.toml

                          printf "%s\n" \
                            "pub fn greet(name: &str) -> String {" \
                            "    format!(\"Hello, {}! From mylib on Redox.\", name)" \
                            "}" \
                            "" \
                            "pub fn add(a: i32, b: i32) -> i32 {" \
                            "    a + b" \
                            "}" \
                            > /tmp/pathdep/mylib/src/lib.rs

                          # Main crate depending on mylib
                          printf "%s\n" \
                            "[package]" \
                            "name = \"pathdep\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            "" \
                            "[dependencies]" \
                            "mylib = { path = \"mylib\" }" \
                            > /tmp/pathdep/Cargo.toml

                          printf "%s\n" \
                            "use mylib::{greet, add};" \
                            "" \
                            "fn main() {" \
                            "    let msg = greet(\"Redox\");" \
                            "    println!(\"{}\", msg);" \
                            "    println!(\"2 + 3 = {}\", add(2, 3));" \
                            "    if add(2, 3) == 5 && msg.contains(\"mylib\") {" \
                            "        println!(\"PATH_DEP_OK\");" \
                            "    } else {" \
                            "        println!(\"PATH_DEP_FAIL\");" \
                            "    }" \
                            "}" \
                            > /tmp/pathdep/src/main.rs

                          cd /tmp/pathdep
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          # Fresh CARGO_HOME to avoid corrupted flock state from earlier tests
                          rm -rf /tmp/cargo-pathdep
                          mkdir -p /tmp/cargo-pathdep
                          cp /root/.cargo/config.toml /tmp/cargo-pathdep/
                          export CARGO_HOME=/tmp/cargo-pathdep
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc

                          rm -f /root/.cargo/.package-cache* 2>/dev/null
                          rm -f "$CARGO_HOME/.package-cache"* 2>/dev/null

                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>/tmp/pathdep-stderr
                          CARGO_EXIT=$?

                          BIN=./target/x86_64-unknown-redox/debug/pathdep
                          if [ $CARGO_EXIT -eq 0 ] && [ -f "$BIN" ]; then
                            $BIN 2>&1
                            echo "pathdep=$?" > /tmp/pathdep-result
                          else
                            echo "pathdep=$CARGO_EXIT" > /tmp/pathdep-result
                          fi
                        '
                        echo "pathdep result: $(cat /tmp/pathdep-result)"

                        let pathdep_bin = "/tmp/pathdep/target/x86_64-unknown-redox/debug/pathdep"
                        if exists -f $pathdep_bin
                          $pathdep_bin > /tmp/pathdep-run-out ^>/tmp/pathdep-run-err
                          /nix/system/profile/bin/bash -c 'grep -q "PATH_DEP_OK" /tmp/pathdep-run-out'
                          if test $? = 0
                            echo "FUNC_TEST:cargo-path-dep:PASS"
                          else
                            echo "FUNC_TEST:cargo-path-dep:FAIL:bad output"
                            cat /tmp/pathdep-run-out
                          end
                        else
                          echo "FUNC_TEST:cargo-path-dep:FAIL:$(cat /tmp/pathdep-result)"
                          echo "=== pathdep stderr (last 2KB) ==="
                          /nix/system/profile/bin/bash -c 'tail -c 2048 /tmp/pathdep-stderr 2>/dev/null'
                        end

                        # ── Test: Vendored dependency ───────────────────────────
                        # Tests cargo offline build with a vendored crate.
                        # Creates a fake registry crate in vendor/ with proper
                        # .cargo-checksum.json and source replacement config.
                        echo ""
                        echo "--- cargo-vendored-dep: vendored crate dependency ---"
                        /nix/system/profile/bin/bash -c '
                          # Build vendored project
                          rm -rf /tmp/vendored
                          mkdir -p /tmp/vendored/src
                          mkdir -p /tmp/vendored/.cargo
                          mkdir -p /tmp/vendored/vendor/minimath/src

                          # Vendored crate: minimath 0.1.0
                          printf "%s\n" \
                            "[package]" \
                            "name = \"minimath\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            > /tmp/vendored/vendor/minimath/Cargo.toml

                          printf "%s\n" \
                            "/// Compute factorial iteratively" \
                            "pub fn factorial(n: u64) -> u64 {" \
                            "    (1..=n).product()" \
                            "}" \
                            "" \
                            "/// Fibonacci via iterative method" \
                            "pub fn fibonacci(n: u32) -> u64 {" \
                            "    if n <= 1 { return n as u64; }" \
                            "    let (mut a, mut b) = (0u64, 1u64);" \
                            "    for _ in 2..=n {" \
                            "        let c = a + b;" \
                            "        a = b;" \
                            "        b = c;" \
                            "    }" \
                            "    b" \
                            "}" \
                            > /tmp/vendored/vendor/minimath/src/lib.rs

                          # cargo-checksum.json (empty files hash = valid for vendored sources)
                          echo "{\"files\":{}}" > /tmp/vendored/vendor/minimath/.cargo-checksum.json

                          # Cargo source replacement config (project-local; global config has build/target/gc)
                          printf "%s\n" \
                            "[source.crates-io]" \
                            "replace-with = \"vendored-sources\"" \
                            "" \
                            "[source.vendored-sources]" \
                            "directory = \"vendor\"" \
                            > /tmp/vendored/.cargo/config.toml

                          # Main project
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
                            "use minimath::{factorial, fibonacci};" \
                            "" \
                            "fn main() {" \
                            "    let f5 = factorial(5);" \
                            "    let fib10 = fibonacci(10);" \
                            "    println!(\"5! = {}\", f5);" \
                            "    println!(\"fib(10) = {}\", fib10);" \
                            "    if f5 == 120 && fib10 == 55 {" \
                            "        println!(\"VENDORED_OK\");" \
                            "    } else {" \
                            "        println!(\"VENDORED_FAIL: f5={} fib10={}\", f5, fib10);" \
                            "    }" \
                            "}" \
                            > /tmp/vendored/src/main.rs

                          # Cargo.lock (must exist for --offline vendored builds)
                          printf "%s\n" \
                            "# This file is automatically @generated by Cargo." \
                            "# It is not intended for manual editing." \
                            "version = 3" \
                            "" \
                            "[[package]]" \
                            "name = \"minimath\"" \
                            "version = \"0.1.0\"" \
                            "source = \"registry+https://github.com/rust-lang/crates.io-index\"" \
                            "" \
                            "[[package]]" \
                            "name = \"vendored-test\"" \
                            "version = \"0.1.0\"" \
                            "dependencies = [" \
                            " \"minimath\"," \
                            "]" \
                            > /tmp/vendored/Cargo.lock

                          cd /tmp/vendored
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          rm -rf /tmp/cargo-vendored
                          mkdir -p /tmp/cargo-vendored
                          cp /root/.cargo/config.toml /tmp/cargo-vendored/
                          export CARGO_HOME=/tmp/cargo-vendored
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc

                          rm -f /root/.cargo/.package-cache* 2>/dev/null
                          rm -f "$CARGO_HOME/.package-cache"* 2>/dev/null

                          # Merge stderr into stdout so errors show on serial console
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>&1
                          CARGO_EXIT=$?
                          echo "[vendored] cargo exit=$CARGO_EXIT"

                          BIN=./target/x86_64-unknown-redox/debug/vendored-test
                          if [ $CARGO_EXIT -eq 0 ] && [ -f "$BIN" ]; then
                            $BIN 2>&1
                            echo "vendored=$?" > /tmp/vendored-result
                          else
                            echo "vendored=$CARGO_EXIT" > /tmp/vendored-result
                          fi
                        '
                        echo "vendored result: $(cat /tmp/vendored-result)"

                        let vendored_bin = "/tmp/vendored/target/x86_64-unknown-redox/debug/vendored-test"
                        if exists -f $vendored_bin
                          $vendored_bin > /tmp/vendored-run-out ^>/tmp/vendored-run-err
                          /nix/system/profile/bin/bash -c 'grep -q "VENDORED_OK" /tmp/vendored-run-out'
                          if test $? = 0
                            echo "FUNC_TEST:cargo-vendored-dep:PASS"
                          else
                            echo "FUNC_TEST:cargo-vendored-dep:FAIL:bad output"
                            cat /tmp/vendored-run-out
                          end
                        else
                          echo "FUNC_TEST:cargo-vendored-dep:FAIL:$(cat /tmp/vendored-result)"
                          echo "=== vendored stderr (last 2KB) ==="
                          /nix/system/profile/bin/bash -c 'tail -c 2048 /tmp/vendored-stderr 2>/dev/null'
                        end

                        # ── Test: Proc-macro crate ──────────────────────────────
                        # THE milestone test. Proc-macros compile as .so files that
                        # rustc dlopen()s at compile time. If this works, the entire
                        # serde/clap/tokio ecosystem is within reach on Redox.
                        echo ""
                        echo "--- cargo-proc-macro: proc-macro dependency ---"
                        /nix/system/profile/bin/bash -c '
                          # Build proc-macro project
                          rm -rf /tmp/procmacro
                          mkdir -p /tmp/procmacro/src
                          mkdir -p /tmp/procmacro/.cargo
                          mkdir -p /tmp/procmacro/vendor/my-derive/src

                          # Proc-macro crate: my-derive 0.1.0
                          printf "%s\n" \
                            "[package]" \
                            "name = \"my-derive\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            "" \
                            "[lib]" \
                            "proc-macro = true" \
                            > /tmp/procmacro/vendor/my-derive/Cargo.toml

                          # A simple derive macro that generates a describe() method
                          printf "%s\n" \
                            "extern crate proc_macro;" \
                            "use proc_macro::TokenStream;" \
                            "" \
                            "#[proc_macro_derive(Describe)]" \
                            "pub fn describe_derive(input: TokenStream) -> TokenStream {" \
                            "    let input_str = input.to_string();" \
                            "    let name = input_str" \
                            "        .split_whitespace()" \
                            "        .skip_while(|w| *w != \"struct\")" \
                            "        .nth(1)" \
                            "        .unwrap_or(\"Unknown\")" \
                            "        .trim_end_matches(\"{\")" \
                            "        .trim_end_matches(\";\");" \
                            "    let output = format!(" \
                            "        \"impl {} {{ pub fn describe() -> String {{ String::from(\\\"{}\\\") }} }}\"," \
                            "        name, name" \
                            "    );" \
                            "    output.parse().unwrap()" \
                            "}" \
                            > /tmp/procmacro/vendor/my-derive/src/lib.rs

                          echo "{\"files\":{}}" > /tmp/procmacro/vendor/my-derive/.cargo-checksum.json

                          # Cargo config with vendor source replacement (project-local)
                          printf "%s\n" \
                            "[source.crates-io]" \
                            "replace-with = \"vendored-sources\"" \
                            "" \
                            "[source.vendored-sources]" \
                            "directory = \"vendor\"" \
                            > /tmp/procmacro/.cargo/config.toml

                          printf "%s\n" \
                            "[package]" \
                            "name = \"procmacro-test\"" \
                            "version = \"0.1.0\"" \
                            "edition = \"2021\"" \
                            "" \
                            "[dependencies]" \
                            "my-derive = \"0.1.0\"" \
                            > /tmp/procmacro/Cargo.toml

                          printf "%s\n" \
                            "use my_derive::Describe;" \
                            "" \
                            "#[derive(Describe)]" \
                            "struct Widget {" \
                            "    x: i32," \
                            "    y: i32," \
                            "}" \
                            "" \
                            "#[derive(Describe)]" \
                            "struct Button;" \
                            "" \
                            "fn main() {" \
                            "    let w_desc = Widget::describe();" \
                            "    let b_desc = Button::describe();" \
                            "    println!(\"Widget: {}\", w_desc);" \
                            "    println!(\"Button: {}\", b_desc);" \
                            "    if w_desc == \"Widget\" && b_desc == \"Button\" {" \
                            "        println!(\"PROC_MACRO_OK\");" \
                            "    } else {" \
                            "        println!(\"PROC_MACRO_FAIL: w={} b={}\", w_desc, b_desc);" \
                            "    }" \
                            "}" \
                            > /tmp/procmacro/src/main.rs

                          printf "%s\n" \
                            "version = 3" \
                            "" \
                            "[[package]]" \
                            "name = \"my-derive\"" \
                            "version = \"0.1.0\"" \
                            "source = \"registry+https://github.com/rust-lang/crates.io-index\"" \
                            "" \
                            "[[package]]" \
                            "name = \"procmacro-test\"" \
                            "version = \"0.1.0\"" \
                            "dependencies = [" \
                            " \"my-derive\"," \
                            "]" \
                            > /tmp/procmacro/Cargo.lock

                          cd /tmp/procmacro
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          rm -rf /tmp/cargo-procmacro
                          mkdir -p /tmp/cargo-procmacro
                          cp /root/.cargo/config.toml /tmp/cargo-procmacro/
                          export CARGO_HOME=/tmp/cargo-procmacro
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc

                          rm -f /root/.cargo/.package-cache* 2>/dev/null
                          rm -f "$CARGO_HOME/.package-cache"* 2>/dev/null

                          # Merge stderr into stdout so errors show on serial console
                          /nix/system/profile/bin/bash /tmp/cargo-build-safe 2>&1
                          CARGO_EXIT=$?
                          echo "[procmacro] cargo exit=$CARGO_EXIT"

                          BIN=./target/x86_64-unknown-redox/debug/procmacro-test
                          if [ $CARGO_EXIT -eq 0 ] && [ -f "$BIN" ]; then
                            $BIN 2>&1
                            echo "procmacro=$?" > /tmp/procmacro-result
                          else
                            echo "procmacro=$CARGO_EXIT" > /tmp/procmacro-result
                          fi
                        '
                        echo "procmacro result: $(cat /tmp/procmacro-result)"

                        let pm_bin = "/tmp/procmacro/target/x86_64-unknown-redox/debug/procmacro-test"
                        if exists -f $pm_bin
                          $pm_bin > /tmp/procmacro-run-out ^>/tmp/procmacro-run-err
                          /nix/system/profile/bin/bash -c 'grep -q "PROC_MACRO_OK" /tmp/procmacro-run-out'
                          if test $? = 0
                            echo "FUNC_TEST:cargo-proc-macro:PASS"
                          else
                            echo "FUNC_TEST:cargo-proc-macro:FAIL:bad output"
                            cat /tmp/procmacro-run-out
                            cat /tmp/procmacro-run-err
                          end
                        else
                          echo "FUNC_TEST:cargo-proc-macro:FAIL:$(cat /tmp/procmacro-result)"
                          echo "=== procmacro stderr (last 4KB) ==="
                          /nix/system/profile/bin/bash -c 'tail -c 4096 /tmp/procmacro-stderr 2>/dev/null'
                          echo "=== procmacro stdout (last 2KB) ==="
                          /nix/system/profile/bin/bash -c 'tail -c 2048 /tmp/procmacro-stdout 2>/dev/null'
                        end

                        # ══════════════════════════════════════════════════════
                        # Phase 4: snix build — Nix derivation builder on Redox
                        # ══════════════════════════════════════════════════════
                        #
                        # These tests prove that `snix build --expr` can:
                        #   1. Evaluate a Nix expression to a derivation
                        #   2. Execute the builder program
                        #   3. Produce output in /nix/store/
                        #   4. Register the output in PathInfoDb
                        #
                        # This is the "Nix builds on Redox" milestone.

                        echo ""
                        echo "========================================"
                        echo "  SNIX BUILD TESTS"
                        echo "========================================"
                        echo ""

                        # All snix build tests run inside single bash blocks to avoid
                        # Ion $? issues between external commands. The FUNC_TEST verdict
                        # is echoed from inside bash.
                        # Derivations set PATH so the builder can find mkdir, cat, chmod.
                        # No cut command on Redox — use bash parameter expansion instead.

                        # ── Test: snix build simple file output ─────────────
                        echo "--- snix-build-simple: basic derivation ---"
                        /nix/system/profile/bin/bash -c '
                          mkdir -p /nix/store /nix/var/snix/pathinfo
                          OUTPUT=$(/bin/snix build --expr "derivation { name = \"snix-build-test\"; builder = \"/nix/system/profile/bin/bash\"; args = [\"-c\" \"echo snix-build-works > \\\$out\"]; system = \"x86_64-unknown-redox\"; }" 2>/tmp/snix-build-simple-err)
                          EXIT=$?
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
                            cat /tmp/snix-build-simple-err 2>/dev/null
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
                          P="/nix/system/profile/bin"
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
                            # Redox grep has no \| alternation — check each pattern
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
                        # The crown jewel of the snix-build tests: a Nix
                        # derivation that runs cargo build to compile a Rust
                        # hello-world, producing a real ELF binary in
                        # /nix/store/. Proves: eval → derivationStrict →
                        # cargo build → link → ELF → runs on Redox.
                        # ── Test: snix build compiles a Rust crate ─────────
                        # The crown jewel: a Nix derivation that runs cargo
                        # to compile a Rust hello-world. Builder output goes
                        # to the terminal (Stdio::inherit in build_derivation).
                        echo "--- snix-build-cargo: Rust crate in Nix derivation ---"
                        /nix/system/profile/bin/bash -c '
                          # Write builder script (bash, not executable — no chmod)
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
        # cargo timeout+retry — handles intermittent startup hangs
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
            cat /scheme/sys/uname >/dev/null 2>/dev/null
          done
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

                          # Clear stale cc-wrapper debug files
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
                            echo "=== cc-wrapper-raw-args ==="
                            cat /tmp/.cc-wrapper-raw-args 2>/dev/null
                            echo "=== cc-wrapper-stderr (lld errors) ==="
                            cat /tmp/.cc-wrapper-stderr 2>/dev/null
                            echo "=== cc-wrapper-last-err ==="
                            cat /tmp/.cc-wrapper-last-err 2>/dev/null
                            echo "=== end debug ==="
                          fi
                        '

                        # ── Test: Self-compile snix on Redox ─────────────────
                        # THE ultimate self-hosting test. Compile snix-redox
                        # (a real 45K-line Rust project with 183 crate deps,
                        # proc-macros, and a bytecode VM) from source on Redox.
                        echo ""
                        echo "========================================"
                        echo "  SNIX SELF-COMPILE TEST"
                        echo "========================================"
                        echo ""

                        # Check if source bundle was included on the image
                        if exists -d /usr/src/snix-redox
                          echo "FUNC_TEST:snix-src-present:PASS"
                        else
                          echo "FUNC_TEST:snix-src-present:FAIL:source bundle not found at /usr/src/snix-redox"
                        end

                        # Check if vendor directory exists
                        if exists -d /usr/src/snix-redox/vendor
                          echo "FUNC_TEST:snix-vendor-present:PASS"
                        else
                          echo "FUNC_TEST:snix-vendor-present:FAIL:vendor dir not found"
                        end

                        # Run the full cargo build in a bash block
                        echo "--- snix self-compile: cargo build --offline ---"
                        /nix/system/profile/bin/bash -c '
                          set -x

                          # Copy source to writable directory (rootTree is read-only)
                          rm -rf /tmp/snix-build
                          cp -r /usr/src/snix-redox /tmp/snix-build
                          cd /tmp/snix-build

                          # Create .cargo dir (cp -r may skip dotfiles from Nix store)
                          mkdir -p /tmp/snix-build/.cargo

                          # Write merged cargo config into the project .cargo dir.
                          # Combines vendor source replacement with Redox target settings.
                          cat > /tmp/snix-build/.cargo/config.toml << CARGOEOF
        [source.crates-io]
        replace-with = "vendored-sources"

        [source.vendored-sources]
        directory = "vendor"

        [build]
        target = "x86_64-unknown-redox"

        [target.x86_64-unknown-redox]
        linker = "/nix/system/profile/bin/cc"
  CARGOEOF

                          # Use a fresh CARGO_HOME (no stale lock files from earlier tests)
                          rm -rf /tmp/cargo-snix
                          mkdir -p /tmp/cargo-snix
                          export CARGO_HOME=/tmp/cargo-snix
                          export LD_LIBRARY_PATH="/nix/system/profile/lib:/usr/lib/rustc:/lib"
                          export CARGO_BUILD_JOBS=2
                          export CARGO_INCREMENTAL=0
                          export RUSTC=/nix/system/profile/bin/rustc
                          # cc-rs crate defaults to "ar" but we only have llvm-ar
                          export AR=/nix/system/profile/bin/llvm-ar

                          # Clean any stale lock files
                          rm -f /tmp/cargo-snix/.package-cache* 2>/dev/null

                          echo "[snix-build] Starting cargo build (JOBS=2)..."
                          echo "[snix-build] Vendor crates: $(ls vendor/ | wc -l)"

                          # Build with timeout — this is a BIG compile (168 crates).
                          # JOBS=2 works since the fork-lock fix (yield-based RW lock
                          # replacing futex-based CLONE_LOCK) and lld-wrapper (16MB stack).
                          #
                          # IMPORTANT: Use file redirection, NOT pipes. Pipes on Redox break
                          # with deep process hierarchies (cargo->rustc->cc->lld). The pipe reader
                          # exits early, losing cargo output and corrupting the exit code.
                          MAX_TIME=1800
                          echo "[snix-build] About to run cargo build..." > /tmp/snix-build-log
                          cargo build --offline >> /tmp/snix-build-log 2>&1 &
                          PID=$!
                          SECONDS=0
                          LAST_REPORT=0
                          while kill -0 $PID 2>/dev/null; do
                            if [ $SECONDS -ge $MAX_TIME ]; then
                              echo "[snix-build] TIMEOUT after ''${MAX_TIME}s" >&2
                              kill $PID 2>/dev/null; wait $PID 2>/dev/null
                              kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
                              echo "snix-build=TIMEOUT" > /tmp/snix-build-result
                              exit 0
                            fi
                            # Progress indicator every 60s
                            ELAPSED=$SECONDS
                            if [ $((ELAPSED - LAST_REPORT)) -ge 60 ] && [ $ELAPSED -gt 0 ]; then
                              echo "[snix-build] ''${ELAPSED}s elapsed..."
                              LAST_REPORT=$ELAPSED
                            fi
                            cat /scheme/sys/uname >/dev/null 2>/dev/null
                          done
                          wait $PID
                          echo "snix-build=$?" > /tmp/snix-build-result
                        '

                        echo "=== snix build result ==="
                        cat /tmp/snix-build-result

                        # Check compilation result
                        let snix_result = $(cat /tmp/snix-build-result)
                        # Check BOTH the exit code AND that the binary was produced
                        # (cargo build can exit 0 due to pipe pipeline but still fail)
                        let snix_bin = "/tmp/snix-build/target/x86_64-unknown-redox/debug/snix"
                        if test "$snix_result" = "snix-build=0"
                          if exists -f $snix_bin
                            echo "FUNC_TEST:snix-compile:PASS"
                          else
                            echo "FUNC_TEST:snix-compile:FAIL:exit-ok-but-no-binary"
                            echo "=== snix build log (last 4KB) ==="
                            /nix/system/profile/bin/bash -c 'tail -c 4096 /tmp/snix-build-log 2>/dev/null'
                            echo "=== CC wrapper raw args ==="
                            cat /tmp/.cc-wrapper-raw-args
                            echo "=== CC wrapper last error ==="
                            cat /tmp/.cc-wrapper-last-err
                            echo "=== CC wrapper stderr ==="
                            cat /tmp/.cc-wrapper-stderr
                            echo "=== CC wrapper shared cmd ==="
                            cat /tmp/.cc-wrapper-shared-cmd
                          end
                        else
                          echo "FUNC_TEST:snix-compile:FAIL:$snix_result"
                          echo "=== snix build log ==="
                          cat /tmp/snix-build-log
                        end

                        # Check if binary was produced
                        let snix_bin = "/tmp/snix-build/target/x86_64-unknown-redox/debug/snix"
                        if exists -f $snix_bin
                          echo "FUNC_TEST:snix-binary-exists:PASS"
                          # Show binary size
                          ls -la $snix_bin

                          # Test: run the self-compiled snix
                          $snix_bin --version > /tmp/snix-selfbuilt-out ^>/tmp/snix-selfbuilt-err
                          let snix_run_exit = $?
                          if test $snix_run_exit = 0
                            echo "FUNC_TEST:snix-binary-runs:PASS"
                            cat /tmp/snix-selfbuilt-out
                          else
                            echo "FUNC_TEST:snix-binary-runs:FAIL:exit $snix_run_exit"
                            cat /tmp/snix-selfbuilt-err
                          end

                          # Test: self-compiled snix can evaluate a Nix expression
                          $snix_bin eval --expr "1 + 1" > /tmp/snix-selfbuilt-eval ^>/tmp/snix-selfbuilt-eval-err
                          let snix_eval_exit = $?
                          if test $snix_eval_exit = 0
                            let eval_result = $(cat /tmp/snix-selfbuilt-eval)
                            if test "$eval_result" = "2"
                              echo "FUNC_TEST:snix-eval-works:PASS"
                            else
                              echo "FUNC_TEST:snix-eval-works:FAIL:expected 2, got $eval_result"
                            end
                          else
                            echo "FUNC_TEST:snix-eval-works:FAIL:eval exited $snix_eval_exit"
                            cat /tmp/snix-selfbuilt-eval-err
                          end
                        else
                          echo "FUNC_TEST:snix-binary-exists:FAIL:binary not produced"
                          echo "FUNC_TEST:snix-binary-runs:FAIL:no binary"
                          echo "FUNC_TEST:snix-eval-works:FAIL:no binary"
                        end

                        # ══════════════════════════════════════════════
                        #  SNIX BUILD .#RIPGREP — FLAKE BUILD OF REAL SOFTWARE
                        # ══════════════════════════════════════════════
                        # The ultimate demo: build ripgrep (a real 55-crate Rust
                        # project) through a Nix flake, entirely inside Redox OS.
                        # Pipeline: snix eval flake.nix → derivationStrict →
                        #   cargo build (55 crates) → link → rg binary → works!
                        echo ""
                        echo "========================================"
                        echo "  SNIX BUILD .#RIPGREP"
                        echo "========================================"
                        echo ""

                        # Check if ripgrep source bundle is present
                        if exists -d /usr/src/ripgrep
                          echo "FUNC_TEST:rg-src-present:PASS"
                        else
                          echo "FUNC_TEST:rg-src-present:FAIL:source bundle not at /usr/src/ripgrep"
                        end

                        if exists -d /usr/src/ripgrep/vendor
                          echo "FUNC_TEST:rg-vendor-present:PASS"
                        else
                          echo "FUNC_TEST:rg-vendor-present:FAIL:vendor dir not found"
                        end

                        # Create a flake project that builds ripgrep from the bundled source
                        echo "--- snix build .#ripgrep ---"
                        /nix/system/profile/bin/bash -c '
                          set -x

                          # Copy source to writable directory
                          rm -rf /tmp/rg-build
                          cp -r /usr/src/ripgrep /tmp/rg-build

                          # Create .cargo dir (may not survive cp from Nix store)
                          mkdir -p /tmp/rg-build/.cargo
                          cat > /tmp/rg-build/.cargo/config.toml << CFGEOF
        [source.crates-io]
        replace-with = "vendored-sources"

        [source.vendored-sources]
        directory = "vendor"

        [build]
        jobs = 2
        target = "x86_64-unknown-redox"

        [target.x86_64-unknown-redox]
        linker = "/nix/system/profile/bin/cc"
  CFGEOF

                          # Create the flake directory
                          mkdir -p /tmp/rg-flake

                          # Write builder script
                          cat > /tmp/rg-flake/build-ripgrep.sh << '"'"'BUILDEOF'"'"'
        set -e
        export PATH=/nix/system/profile/bin:/bin:/usr/bin
        export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
        export HOME="$TMPDIR"
        export CARGO_HOME="$TMPDIR/cargo-home"
        mkdir -p "$CARGO_HOME" "$out/bin"

        cd /tmp/rg-build

        # cargo timeout+retry — handles intermittent startup hangs
        # ALL cargo output to stderr so it does not pollute snix stdout
        MAX_TIME=600
        for attempt in 1 2 3; do
          echo "[builder] ripgrep build attempt $attempt (JOBS=2)" >&2
          cargo build --offline --bin rg -j2 >&2 2>&1 &
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
            cat /scheme/sys/uname >/dev/null 2>/dev/null
          done
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

        # Copy the built binary
        cp target/x86_64-unknown-redox/debug/rg "$out/bin/rg"
        echo "[builder] ripgrep build complete" >&2
  BUILDEOF

                          # Write flake.nix
                          cat > /tmp/rg-flake/flake.nix << '"'"'FLAKEEOF'"'"'
        {
          outputs = { self }: {
            packages."x86_64-unknown-redox".ripgrep = derivation {
              name = "ripgrep-14.1.1";
              system = "x86_64-unknown-redox";
              builder = "/nix/system/profile/bin/bash";
              args = ["/tmp/rg-flake/build-ripgrep.sh"];
            };
          };
        }
  FLAKEEOF

                          # Write flake.lock (no external inputs)
                          cat > /tmp/rg-flake/flake.lock << '"'"'LOCKEOF'"'"'
        {
          "version": 7,
          "root": "root",
          "nodes": {
            "root": {}
          }
        }
  LOCKEOF

                          # Run snix build .#ripgrep!
                          echo "=== Starting snix build .#ripgrep ==="
                          cd /tmp/rg-flake
                          /bin/snix build ".#ripgrep" > /tmp/rg-output 2>/tmp/rg-build-err
                          EXIT=$?
                          # snix prints the output path on its last stdout line
                          # Extract just the /nix/store/... path (builder output may leak to stdout)
                          # Note: tail not available on Redox — use grep only
                          OUTPUT=$(grep "/nix/store/" /tmp/rg-output)
                          echo "=== snix build exit=$EXIT ==="
                          echo "=== output=$OUTPUT ==="

                          if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ] && [ -x "$OUTPUT/bin/rg" ]; then
                            echo "FUNC_TEST:rg-build:PASS"

                            # Test: rg --version
                            VER=$("$OUTPUT/bin/rg" --version 2>&1 | head -1)
                            if echo "$VER" | grep -q "ripgrep"; then
                              echo "FUNC_TEST:rg-version:PASS"
                              echo "  version output: $VER"
                            else
                              echo "FUNC_TEST:rg-version:FAIL:version=$VER"
                            fi

                            # Test: rg actually searches text
                            echo "hello world" > /tmp/rg-test.txt
                            echo "foo bar" >> /tmp/rg-test.txt
                            echo "hello redox" >> /tmp/rg-test.txt
                            RESULT=$("$OUTPUT/bin/rg" "hello" /tmp/rg-test.txt 2>&1)
                            LINES=$(echo "$RESULT" | wc -l)
                            if [ "$LINES" -ge 2 ]; then
                              echo "FUNC_TEST:rg-search:PASS"
                              echo "  search result: $RESULT"
                            else
                              echo "FUNC_TEST:rg-search:FAIL:lines=$LINES result=$RESULT"
                            fi

                            # Test: output is in /nix/store
                            case "$OUTPUT" in
                              /nix/store/*) echo "FUNC_TEST:rg-store-path:PASS" ;;
                              *) echo "FUNC_TEST:rg-store-path:FAIL:$OUTPUT" ;;
                            esac

                            # Test: binary size is reasonable (should be >1MB for ripgrep)
                            # Note: awk not available on Redox, use wc -c instead
                            SIZE=$(wc -c < "$OUTPUT/bin/rg")
                            if [ "$SIZE" -gt 1000000 ]; then
                              echo "FUNC_TEST:rg-binary-size:PASS"
                              echo "  rg binary: $SIZE bytes"
                            else
                              echo "FUNC_TEST:rg-binary-size:FAIL:too small=$SIZE"
                            fi
                          else
                            echo "FUNC_TEST:rg-build:FAIL:exit=$EXIT"
                            echo "FUNC_TEST:rg-version:FAIL:no binary"
                            echo "FUNC_TEST:rg-search:FAIL:no binary"
                            echo "FUNC_TEST:rg-store-path:FAIL:no binary"
                            echo "FUNC_TEST:rg-binary-size:FAIL:no binary"
                            echo "=== build stderr (last 20 lines) ==="
                            tail -20 /tmp/rg-build-err 2>/dev/null
                            echo "=== end stderr ==="
                          fi
                        '

                        # ── JOBS=2 parallel build smoke test ───────────────────
                        # Verifies JOBS=2 on a simple crate (the big builds above
                        # already use JOBS=2 for snix and ripgrep).
                        echo "--- parallel-jobs2 ---"
                        /nix/system/profile/bin/bash -c '
                          mkdir -p /tmp/test-j2
                          cd /tmp/test-j2
                          export CARGO_HOME=/tmp/cargo-home-j2
                          mkdir -p $CARGO_HOME

                          cat > Cargo.toml << TOMLEOF
    [package]
    name = "j2test"
    version = "0.1.0"
    edition = "2021"
  TOMLEOF
                          mkdir -p src
                          echo "fn main() { println!(\"parallel\"); }" > src/main.rs

                          export CARGO_BUILD_JOBS=2
                          cargo build --offline > /tmp/j2-out 2>&1 &
                          PID=$!
                          SECONDS=0
                          TIMEOUT=600
                          while kill -0 $PID 2>/dev/null; do
                            if [ $SECONDS -ge $TIMEOUT ]; then
                              echo "FUNC_TEST:parallel-jobs2:FAIL:timeout after ''${TIMEOUT}s"
                              kill $PID 2>/dev/null; wait $PID 2>/dev/null
                              kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
                              rm -rf /tmp/test-j2 /tmp/cargo-home-j2
                              exit 0
                            fi
                            cat /scheme/sys/uname > /dev/null 2>&1
                          done
                          wait $PID
                          RC=$?
                          if [ $RC -eq 0 ]; then
                            echo "FUNC_TEST:parallel-jobs2:PASS"
                            echo "  JOBS=2 completed in ''${SECONDS}s"
                          else
                            echo "FUNC_TEST:parallel-jobs2:FAIL:exit=$RC"
                            cat /tmp/j2-out 2>/dev/null | head -10
                          fi
                          rm -rf /tmp/test-j2 /tmp/cargo-home-j2
                        '

                        echo ""
                        echo "FUNC_TESTS_COMPLETE"
  '';

  # Build from the self-hosting profile
  selfHosting = import ./self-hosting.nix { inherit pkgs lib; };
in
selfHosting
// {
  # Override boot to use a larger disk (source bundle + build artifacts)
  "/boot" = (selfHosting."/boot" or { }) // {
    diskSizeMB = 8192;
  };

  # Disable sandbox — per-path proxy is not yet validated for complex
  # cargo builds with 100+ crates and deep process hierarchies.
  "/snix" = {
    sandbox = false;
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

  # Include snix source bundle on the filesystem for self-compile test
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
      );
  };
}
