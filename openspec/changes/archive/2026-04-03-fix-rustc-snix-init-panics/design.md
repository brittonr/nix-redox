## Context

The self-hosting image has a working Rust cross-toolchain (rustc, cargo, lld, clang, sysroot) and snix installed. After the per-function unwind stub fix, binaries no longer hang with "error 0". But two distinct init failures remain:

1. **rustc**: `rustc -vV` works (simple version query). `rustc --emit=obj` works (LLVM codegen). But `rustc --print cfg` exits 1 — it goes through LLVM option parsing / session init which triggers a panic somewhere. With `RAYON_NUM_THREADS=4` set, the Rayon `available_parallelism()` panic is avoided, but something else still panics.

2. **snix**: Exits 134 (abort) immediately. Compiled with `panic=abort`, so any panic during startup hits `abort()` → `_exit(134)`. No diagnostic output — the panic message goes to stderr which may not be captured, and with panic=abort there's no unwind/backtrace.

Key constraints:
- `librustc_driver.so` uses panic=unwind (Rust bootstrap default). The per-function stubs mean `_Unwind_RaiseException` stays in the archive unless pulled — but librustc_driver still has the stub as a local symbol from compilation.
- snix is panic=abort — any panic is fatal with no backtrace.
- Serial console captures stderr from the test scripts, but panics may write to fd 2 before relibc is fully set up.
- The kernel syscall debug module can trace syscalls from specific processes if needed.

## Goals / Non-Goals

**Goals:**
- Capture the actual panic message from `rustc --print cfg` (what panics and why)
- Capture diagnostic output from snix to identify which init code path aborts
- Fix both init failures so rustc compilation and snix builds work on-guest
- Get the self-hosting test suite compilation tests passing (cargo build, snix build, two-step compile)

**Non-Goals:**
- Fixing all 51 failing tests — some may have separate root causes
- Changing panic strategy (panic=abort stays for userspace, panic=unwind stays for rustc DSO)
- Full LLVM feature parity on Redox — just enough to compile Rust code
- Upstream relibc patches — keep fixes in our patch set

## Decisions

### 1. Diagnostic capture strategy

**Decision**: Build a diagnostic image that wraps rustc and snix to capture panic output, then boot it in QEMU to read serial output.

**Approach**:
- For rustc: set `RUST_BACKTRACE=1` and redirect stderr to a file, then cat it. `rustc --print cfg 2>/tmp/rustc-panic.log; cat /tmp/rustc-panic.log`
- For snix: same approach, plus use `strace-redox` to trace syscalls during init. `strace snix --version 2>/tmp/snix-strace.log`
- If stderr capture isn't enough, use kernel syscall debug (`kernelSyscallDebug` with `debugProcesses = ["rustc", "snix"]`) to see what syscalls fail.

**Rationale**: We don't know what panics yet. Changing code without the panic message risks whack-a-mole. 10 minutes of diagnostic capture saves hours of guessing.

### 2. Likely root causes (ranked)

Based on prior Redox self-hosting experience:

1. **Unimplemented sysconf / procfs query**: LLVM or Rayon probes `/proc/cpuinfo`, `sysconf(_SC_NPROCESSORS_ONLN)`, or similar. Redox has no `/proc` filesystem and sysconf is partially implemented. `RAYON_NUM_THREADS=4` handles Rayon but LLVM may have its own parallelism probe.
2. **Missing environment variable**: LLVM needs `HOME`, `TMPDIR`, or a locale setting. Missing vars cause `unwrap()` on `env::var()` → panic.
3. **File not found during init**: snix may try to open `/nix/var/nix/db/` or similar state directory that doesn't exist on a fresh image.
4. **Stack overflow in LLVM init**: `rustc --print cfg` loads more LLVM code than `--emit=obj` somehow, hitting the main thread stack limit.

### 3. Fix strategy

**Decision**: Fix in priority order — environment first (cheap), then syscall stubs (moderate), then code changes (expensive).

- **Environment fixes**: Add missing env vars to self-hosting profile (`HOME`, `TMPDIR`, `LANG=C`, `LLVM_*` flags to disable problematic features).
- **Syscall stubs**: If sysconf or procfs is the issue, patch relibc to return sane defaults instead of panicking.
- **Code changes**: Last resort — patch snix or rustc wrapper scripts to work around init issues.

### 4. Validation sequence

Same 3-step escalation as the unwind stub fix:
1. `rustc --print cfg` exits 0
2. `rustc -o binary -C linker=cc empty.rs` exits 0
3. `snix build --expr "derivation { ... }"` exits 0

Then run the full 76-test suite.

## Risks / Trade-offs

**[Multiple independent root causes]** — rustc and snix may panic for different reasons. Fixing one doesn't fix the other. Mitigation: diagnose both independently, fix in parallel.

**[Diagnostic capture may not show the panic]** — With panic=abort, the process dies before flushing stderr. Mitigation: use strace-redox for syscall-level visibility, kernel debug for deep tracing.

**[Environment changes may mask real bugs]** — Setting `LLVM_ENABLE_THREADS=0` or similar may fix the panic but disable useful LLVM features. Mitigation: prefer targeted fixes (sysconf returns correct value) over blanket disables.

**[Sysroot rebuild cascade]** — If relibc patches are needed, all packages rebuild (~45 min). Mitigation: test relibc changes in isolation before full rebuild.
