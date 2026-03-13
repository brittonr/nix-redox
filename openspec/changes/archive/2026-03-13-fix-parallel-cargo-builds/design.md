## Context

The parallel cargo build story on Redox has three layers of fixes:

1. **lld-wrapper** (deployed) — gives ld.lld a 16MB stack via thread spawn + exec. Prevents stack overflow on the Redox kernel's ~8KB main-thread stack.
2. **patch-relibc-fork-lock.py** (deployed) — replaces CLONE_LOCK's futex-based RwLock with a yield-based AtomicI32 lock. Fixes lost-wake bug during CoW address space duplication in fork.
3. **cc wrapper** (deployed) — bash script in redox-sysroot.nix that routes link steps through lld-wrapper. Already uses `LLD=/nix/system/profile/bin/lld-wrapper`.

The parallel-build-test profile (which uses `linker = ld.lld` directly in its cargo config) passes all 12 tests. But the self-hosting test's `parallel-jobs2` test (which uses the cc wrapper path via `linker = "/nix/system/profile/bin/cc"`) crashes. Since the cc wrapper already uses lld-wrapper, the crash root cause is unknown — possibly a bash process overhead issue, a pipe/fd inheritance problem under concurrent link invocations, or a stale test observation.

## Goals / Non-Goals

**Goals:**
- Diagnose the parallel-jobs2 crash root cause
- Fix whatever is causing it
- Validate JOBS=2 across the full self-hosting test (62+ tests)
- Archive the two investigation changes
- Leave AGENTS.md and napkin accurate

**Non-Goals:**
- Fixing the kernel-level futex CoW bug (that's a kernel project, the yield-based lock works)
- JOBS>2 support (JOBS=2 is the target; higher parallelism can be a follow-up)
- Kernel instrumentation for the deferred parallel hang tasks (permanently deferred)

## Decisions

**Build self-hosting-test first, then diagnose.** The parallel-jobs2 crash was observed in a prior build. The fork-lock and lld-wrapper fixes have both landed since. The crash may already be fixed. Build and run the test; only investigate if it still fails.

**If crash persists, add diagnostics to the cc wrapper.** The bash cc wrapper runs lld-wrapper in background (`&`), closes stdout/stderr, and waits. Under JOBS=2, two cc wrapper instances run concurrently. Possible failure modes:
- FD inheritance: child process inherits open FDs from the cc wrapper bash, causing pipe confusion
- Race on `/tmp/.cc-wrapper-*` debug files: two concurrent invocations overwrite each other's logs
- lld-wrapper thread creation failure: if relibc's thread creation limit is hit concurrently
- Response file race: two @file expansions colliding

**Archive investigation changes with incomplete task checkmarks.** The tasks in cargo-parallel-hang-investigation sections 5-6 are either done (fork-lock fix deployed, JOBS=2 working in parallel-build-test) or superseded. The tasks in fix-remaining-os-bugs section 3 are permanently deferred (kernel instrumentation). Archiving with a note is correct.

## Risks / Trade-offs

[Self-hosting-test build is slow (~30 min)] → Run once, capture full serial log for analysis. Don't rebuild repeatedly.

[Parallel-jobs2 crash might be intermittent] → If it passes on first run, run 3x to check for flakiness before declaring fixed.

[Napkin claim about "lld inside clang" is wrong] → The cc wrapper does NOT run lld inside clang. It calls lld-wrapper directly. Update napkin to correct this.
