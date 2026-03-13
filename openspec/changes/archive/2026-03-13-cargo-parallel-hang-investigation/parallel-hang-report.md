# Parallel Cargo Build Hang — Investigation Report

## Status: FIXED ✓ (2026-03-12)

## Root Cause

**Redox kernel futex bug: lost wake after CoW address space duplication.**

relibc's `CLONE_LOCK` (an `RwLock<()>`) serializes `fork()` (write lock) and thread creation (read lock). The RwLock uses futex-based waiting. When thread A holds the write lock and calls `fork_impl()`, the kernel CoW-duplicates the entire address space, including thread B's in-kernel futex_wait state. After `fork_impl` returns and thread A unlocks, `futex_wake()` fails to wake thread B because the wake targets the wrong physical page (the original pre-CoW page, not thread B's actual page).

### Why it manifests as "one fork works, the other hangs"

1. Thread A and B both call `fork()` concurrently
2. Thread A acquires `CLONE_LOCK.write()` first
3. Thread B's `CLONE_LOCK.write()` fails the CAS, enters `futex_wait()` on the lock state
4. Thread A runs `fork_impl()` — this CoW-duplicates the address space, including the page containing `CLONE_LOCK`
5. Thread A's `fork_impl` returns, guard drops, `CLONE_LOCK.unlock()` stores 0, calls `futex_wake()`
6. **BUG**: `futex_wake()` wakes waiters on the ORIGINAL physical page, but thread B's `futex_wait()` may now reference a DIFFERENT physical page (due to CoW). Thread B is never woken.

### Key evidence

- `CLONE_LOCK.write()` is where thread B hangs (confirmed by tracing: "pre-CLONE_LOCK" printed, "CLONE_LOCK acquired" never printed)
- `fork_impl()` works perfectly when called concurrently WITHOUT any locking (both forks succeed, all children exit normally)
- The allocator's `pthread_atfork` hooks are never registered (`enable_alloc_after_fork()` is never called), so there is NO allocator lock serialization
- All single-threaded fork tests pass (50 children, pipe I/O, concurrent exits)
- The hang is 100% reproducible with just 2 threads and a Barrier

## Fix

Replace `CLONE_LOCK` (futex-based `RwLock`) with a yield-based RW lock using `AtomicI32` + `sched_yield()`:

```
Patch: nix/pkgs/system/patch-relibc-fork-lock.py
```

- `AtomicI32` state: 0 = unlocked, >0 = reader count (thread creation), -1 = exclusive (fork)
- Writers (fork): CAS(0, -1), yield on failure
- Readers (rlct_clone): CAS(n, n+1) where n >= 0, yield on failure
- No futex involvement — immune to the CoW page issue

## Test Results

All 12 tests pass:

```
FUNC_TEST:waitpid-stress-immediate-50:PASS
FUNC_TEST:waitpid-stress-pipeio-50:PASS
FUNC_TEST:waitpid-stress-concurrent-50:PASS
FUNC_TEST:waitpid-stress-concurrent-forkexec:PASS    ← was hanging
FUNC_TEST:waitpid-stress-concurrent-forkpipes:PASS   ← was hanging
FUNC_TEST:parallel-jobs1-baseline:PASS
FUNC_TEST:parallel-jobs2-build:PASS
FUNC_TEST:parallel-jobs2-ws5:PASS                    ← was hanging
FUNC_TEST:parallel-jobs2-ws10:PASS                   ← was hanging
FUNC_TEST:parallel-jobs2-ws20:PASS                   ← was hanging
FUNC_TEST:parallel-jobs2-ws50:PASS                   ← was hanging
FUNC_TEST:parallel-jobs2-ws100:PASS                  ← was hanging
Total time: 268s
```

## Investigation Timeline

1. Added heartbeat diagnostics to cargo's job queue — identified stuck job pattern
2. Built waitpid stress tests — ruled out waitpid notification loss
3. Built graduated workspace tests (5/10/20/50/100 crates) — showed bug is concurrency, not scale
4. Added `test_concurrent_fork_exec` — reproduced without cargo (two threads + Barrier + fork)
5. Read relibc source — found `CLONE_LOCK` RwLock, `fork_hooks`, allocator atfork
6. Patched `alloc::format!` in fork_impl — no effect (allocator hooks never registered)
7. Added tracing inside `Sys::fork()` — pinpointed hang to `CLONE_LOCK.write()` acquisition
8. Tested with spinlock — still hung (spin loop starves fork_impl on same CPU)
9. Tested with NO locking — all tests pass! fork_impl is thread-safe
10. Replaced CLONE_LOCK with yield-based RW lock — all tests pass

## Broader Impact

This is likely a Redox kernel bug affecting ALL futex-based synchronization across fork:
- Any `futex_wait()` in progress when `fork_impl()` does CoW address space duplication may be lost
- The bug only manifests when the futex variable's page gets COW-split during the fork
- Other futex-based primitives (Mutex, Condvar, Barrier) could hit the same issue in multi-threaded fork scenarios

The yield-based lock is a correct workaround for CLONE_LOCK specifically. A kernel-level fix for the futex CoW interaction would be the proper long-term solution.
