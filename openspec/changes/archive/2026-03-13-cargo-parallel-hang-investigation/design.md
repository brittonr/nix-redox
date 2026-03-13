## Context

Cargo with `CARGO_BUILD_JOBS > 1` hangs indefinitely on multi-crate workspace builds running on Redox OS. The lld stack overflow crash (simple crates at JOBS=2) was fixed by `lld-wrapper` — a 16MB stack-growing launcher. But the hang on larger builds persists. Current evidence:

- JOBS=1 always works, even for 193-crate snix self-compilation
- JOBS=2 single crate and small workspace (3 crates) now pass with lld-wrapper
- JOBS>1 on real-world multi-crate projects hangs at ~115-136 crates
- All known poll()-based code in cargo and rustc has been patched to use threads
- fcntl locking patched to no-op, flock handled by cargo-build-safe timeout wrapper
- waitpid is implemented via proc: scheme IPC (not a direct kernel syscall)
- No `ps`, `strace`, or `/proc` filesystem available on Redox — debugging is blind

The fundamental constraint: we can't see what's happening when the hang occurs. There's no process state introspection on Redox beyond `ls /scheme/proc/`.

## Goals / Non-Goals

**Goals:**
- Determine the exact hang point: which process is stuck, what syscall it's blocked on, and why
- Build diagnostic tooling that works within Redox's constraints (scheme-based I/O, no procfs, limited commands)
- Fix the root cause so JOBS=2 completes workspace builds reliably
- Validate the fix on the existing parallel-build-test profile and a larger project (e.g., ripgrep at 33 crates)
- Update AGENTS.md and napkin with findings

**Non-Goals:**
- Supporting JOBS > 2 (start with JOBS=2, optimize later)
- Fixing the separate flock hang (cargo-build-safe already handles it)
- Replacing the proc: scheme waitpid with a direct syscall (kernel arch change — out of scope)
- Full strace/ptrace implementation (too large; we build targeted diagnostics)

## Decisions

### 1. Build a proc: scheme diagnostic dumper instead of strace

**Choice:** Write a small Rust binary that reads `/scheme/proc/<pid>/` entries to dump process state (blocked status, open file descriptors, pending signals) for all running processes when a timeout is detected.

**Why not strace:** Redox has no ptrace syscall. Building one is a kernel project. Reading proc: scheme entries gives us blocked/running state and file descriptors — enough to identify which process is stuck and what it's waiting on.

**Alternatives considered:**
- Printf debugging in relibc — too scattered, rebuilds are slow
- Kernel serial debug prints — too noisy, hard to correlate with userspace

### 2. Instrument cargo's job management loop with heartbeat logging

**Choice:** Patch cargo's `JobQueue::drain_the_queue()` to emit periodic status lines over stderr: which jobs are active, which are waiting for dependencies, which are waiting for a jobserver token.

**Why:** Cargo's job queue is the orchestrator. When it hangs, we need to know whether it's (a) waiting for a child that already exited (waitpid miss), (b) waiting for a jobserver token that was never returned, or (c) blocked in read2/pipe I/O. Heartbeat output pinpoints which waiting path is stuck.

**Alternatives considered:**
- External timeout + kill (already have cargo-build-safe, but it doesn't tell us WHY)
- Patching rustc — too downstream; cargo is the job manager

### 3. Test with increasing workspace sizes to find the exact threshold

**Choice:** Extend parallel-build-test to create workspaces of 5, 10, 20, 50, and 100 crates with inter-crate dependencies. Run each at JOBS=2 with timeout. Find the smallest workspace that hangs.

**Why:** The current test has 3 crates (passes) and real-world is ~115+ (hangs). Narrowing the threshold tells us whether the issue is a fixed resource limit (fd count, pipe buffer pool) or a probabilistic race (more crates = more likely to hit). An exact threshold also gives us a fast reproducer.

**Alternatives considered:**
- Only test at 3 and 100 — miss the transition point
- Jump straight to 100 — too slow to iterate if we need to test fixes

### 4. Investigate waitpid notification ordering via targeted test program

**Choice:** Write a standalone test that forks N children, each exits immediately, and the parent calls waitpid in a loop. Verify all N exits are collected. Then test with children that do pipe I/O before exiting.

**Why:** The waitpid-via-proc:-scheme path is the most suspect. If it drops notifications when multiple children exit in a small time window, cargo would hang waiting for a child that already exited. A standalone test isolates this from cargo's complexity.

**Alternatives considered:**
- Test only inside cargo — too many variables
- Read proc: scheme source code — we don't have it locally; empirical testing is faster

### 5. Fix approach: targeted relibc/cargo patch, not kernel changes

**Choice:** Once root cause is identified, fix in relibc (poll, waitpid, pipe) or cargo patches (job manager). Avoid kernel changes unless empirical evidence shows the kernel is at fault.

**Why:** relibc patches are already part of our build pipeline. Adding another is straightforward. Kernel changes require rebuilding the kernel, re-imaging, and have wider blast radius.

## Risks / Trade-offs

- **[Risk] Root cause is in the kernel (pipe scheme or proc scheme)** → Mitigation: the diagnostic dumper and waitpid test will clearly show if the kernel is dropping events. If so, we scope a minimal kernel patch as a follow-up change.
- **[Risk] The hang is a probabilistic race that's hard to reproduce in small tests** → Mitigation: the graduated workspace sizes (5→100 crates) and multiple runs per size increase the odds of catching it.
- **[Risk] Diagnostic instrumentation changes timing and masks the bug** → Mitigation: use file-based logging (append to `/tmp/diag.log`) rather than pipe-based stderr, to avoid perturbing the pipe state that may be the bug.
- **[Risk] Large workspace tests are slow in VM** → Mitigation: start with small sizes, only scale up once smaller tests pass. Use `--offline` and pre-vendored deps to minimize I/O.
- **[Trade-off] Heartbeat patches to cargo increase patch surface** → Acceptable: these are diagnostic patches, can be removed once the root cause is found and fixed.
