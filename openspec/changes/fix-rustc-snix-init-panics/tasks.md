## 1. Diagnose rustc init panic

- [x] 1.1 Build a diagnostic self-hosting-test image with `RUST_BACKTRACE=1` set in the environment and extra stderr capture around `rustc --print cfg`
  - Added RUST_BACKTRACE=1, stderr capture for rustc --print cfg, snix init diagnostics, strace-redox package
- [x] 1.2 Boot the diagnostic image, capture the actual panic message and backtrace from `rustc --print cfg` via serial output
  - RESULT: `RELIBC PANIC: panicked at redox-rt/src/thread.rs:10:50: called Option::unwrap() on a None value` — proc_fd is None when thread spawn happens
- [x] 1.3 If panic message is insufficient, use `strace-redox` on `rustc --print cfg` to identify the failing syscall
  - Not needed — panic message was sufficient. strace showed `Function not implemented` errors.
- [x] 1.4 If still unclear, enable `kernelSyscallDebug` with `debugProcesses = ["rustc"]` and capture the syscall trace
  - Not needed.
- [x] 1.5 Identify the root cause: which function panics and why (unimplemented sysconf, missing file, env var, stack overflow, etc.)
  - ROOT CAUSE: librustc_driver.so has `__relibc_init_proc_fd` as LOCAL in .symtab (Rust version script `local: *;`). ld_so's get_sym() only searches .dynsym hash table, can't find it. proc_fd never injected, stays None. Thread spawn unwraps None → panic.

## 2. Diagnose snix init abort

- [x] 2.1 Add stderr capture and `RUST_BACKTRACE=1` around `snix --version` in the diagnostic image (note: panic=abort limits backtrace utility, but the panic message itself is valuable)
  - snix --version PASSES (doesn't init fetcher). snix eval/build abort.
- [x] 2.2 Run `strace-redox snix --version` and capture the syscall trace to identify what fails during init
  - strace showed `Function not implemented` errors. Panic message captured from snix eval stderr.
- [x] 2.3 Identify the root cause: which snix init code path panics (evaluator setup, store path, CLI parsing, etc.)
  - ROOT CAUSE: `src/fetchers/mod.rs:195` — reqwest::Client::builder().build().expect() panics because no CA certificates on Redox. snix eagerly creates HTTP client during SnixStoreIO init.

## 3. Fix rustc init

- [x] 3.1 Implement the fix based on diagnostics (environment variable, relibc patch, LLVM flag, or rustc wrapper change)
  - FIX: patch-relibc-symtab-fallback.py — ld_so scans .symtab for LOCAL __relibc_init_* symbols when .dynsym lookup fails. Adds LocalInitSyms struct to DSO, parses ELF symbol table during construction, uses addresses as fallback in run_init.
- [ ] 3.2 Verify `rustc --print cfg` exits 0
- [ ] 3.3 Verify `rustc -o /tmp/empty -C linker=cc /tmp/empty.rs` exits 0 and binary runs

## 4. Fix snix init

- [x] 4.1 Implement the fix based on diagnostics (environment variable, snix code change, relibc patch, or missing directory creation)
  - FIX: snix-redox/src/main.rs — set SSL_CERT_FILE=/dev/null when no system CA certs exist, so rustls initializes with empty root store instead of panicking. Also patched upstream/glue fetcher to fall back to danger_accept_invalid_certs.
- [ ] 4.2 Verify `snix --version` exits 0
- [ ] 4.3 Verify `snix eval --expr "1 + 1"` exits 0
- [ ] 4.4 Verify `snix build --expr "derivation { name = \"test\"; system = \"x86_64-redox\"; builder = \"/bin/echo\"; }"` exits 0

## 5. Validate compilation pipeline

- [ ] 5.1 Verify `cargo build` on a hello world project succeeds
- [ ] 5.2 Rebuild the full self-hosting-test image with fixes
- [ ] 5.3 Run the 76-test suite and compare pass/fail counts — compilation tests (rustc-print-cfg, two-step-compile, hello-two-step, cargo-build-hello) should now pass
- [ ] 5.4 Update AGENTS.md with root causes and fix details
