# Parallel Cargo Build Hang — Investigation Report

## Status: Root Cause Pattern Identified (2026-03-11)

## Findings Summary

The JOBS>1 hang occurs on the **very first concurrent pair** of rustc processes, not at some threshold of ~115 crates as previously believed. One of the first two rustc processes spawned concurrently hangs permanently, while the second job slot continues normally and completes all remaining crates serially.

## Evidence

### Heartbeat Diagnostics (CARGO_DIAG_LOG)

**ws5 (5 independent binary crates, JOBS=2):**
```
[heartbeat t=5s]  active=1 pending=0 tokens=0 finished=4/5 jobs=[crate-001(id=3)]
[heartbeat t=10s] active=1 pending=0 tokens=0 finished=4/5 jobs=[crate-001(id=3)]
[heartbeat t=55s] active=1 pending=0 tokens=0 finished=4/5 jobs=[crate-001(id=3)]
```
→ 4/5 completed. crate-001 stuck forever.

**ws20 (20 independent binary crates, JOBS=2):**
```
[heartbeat t=5s]  active=2 pending=17 tokens=1 finished=1/20 ...
[heartbeat t=60s] active=2 pending=0  tokens=1 finished=18/20 ...
[heartbeat t=65s] active=1 pending=0  tokens=0 finished=19/20 jobs=[crate-001(id=1)]
[heartbeat t=100s] active=1 pending=0 tokens=0 finished=19/20 jobs=[crate-001(id=1)]
```
→ Two jobs run concurrently. 19/20 completed. crate-001 stuck forever.

**ws100 (100 independent binary crates, JOBS=2):**
```
[heartbeat t=5s] active=2 pending=98 tokens=1 finished=0/100 jobs=[crate-023(id=1), crate-092(id=0)]
...
[heartbeat t=100s] active=2 pending=79 tokens=1 finished=19/100 jobs=[crate-023(id=1), crate-094(id=20)]
```
→ crate-023 stuck from the start. Second slot chews through 19 crates in 100s.

### Pattern

1. Cargo spawns 2 rustc processes (first concurrent pair)
2. One hangs permanently — cargo sees it as "active" but gets no output/exit
3. The second slot runs normally, picking up new crates as they queue
4. After all other crates finish, cargo waits forever for the stuck one
5. This is 100% reproducible — happens on every run

### What Was Ruled Out

| Theory | Evidence Against |
|--------|-----------------|
| **waitpid notification loss** | All 3 waitpid stress tests PASS (50 children, immediate/pipe/concurrent) |
| **Threshold-based (115 crates)** | Happens at 5 crates — the issue is concurrency, not scale |
| **Jobserver token starvation** | Heartbeat shows tokens=1 during concurrent phase — token management works |
| **Cargo job queue deadlock** | Cargo's queue drains correctly for all non-stuck jobs |
| **lld stack overflow** | Single-crate JOBS=2 PASS — lld-wrapper stack growth works |
| **Chain dependency serialization** | Independent crates expose the issue; chains masked it (always active=1) |

### Remaining Theories

1. **relibc fork()/exec() race condition** — Two concurrent fork+exec sequences corrupt shared relibc state. First fork succeeds, second fork leaves the child in a broken state.

2. **Pipe creation race** — Concurrent pipe() calls create overlapping file descriptors. One rustc gets a corrupt pipe, hangs reading stdout/stderr.

3. **read2 thread + fork interaction** — Cargo's read2 spawns a background thread per job. The background thread from job A may inherit state into job B's fork(), causing the child to deadlock on a lock held by the (now-dead) thread clone.

4. **Mutex deadlock across fork** — AGENTS.md notes: "Mutex is non-reentrant — child inherits locked state after fork() → deadlock". If the first rustc is forking a child (cc) while the second rustc is also being forked, the second child may inherit a locked mutex.

### Most Likely: Mutex deadlock across fork (#4)

The pattern — one process stuck, the other works — is classic fork-after-lock behavior. Process A acquires a lock, process B forks while A holds the lock. B's child inherits the locked mutex but the thread that would unlock it doesn't exist in the child. B's child hangs on the next access to that lock.

In this case: cargo spawns rustc-1 and rustc-2 concurrently. Both go through fork()+exec(). If relibc has a global mutex (e.g., for memory allocation or CWD) that one fork() holds when the other fork() runs, the child from the second fork inherits the locked mutex and deadlocks.

## Root Cause Confirmed: relibc fork() is not thread-safe (2026-03-11)

### Minimal Reproducer

```rust
// Two threads call fork() simultaneously via a Barrier
let barrier = Arc::new(Barrier::new(2));
let t1 = thread::spawn(move || { barrier.wait(); fork(); waitpid(...) });
let t2 = thread::spawn(move || { barrier.wait(); fork(); waitpid(...) });
// Result: one thread's child hangs permanently, the other completes
```

The `test_concurrent_fork_exec` test in `waitpid-stress` hangs on the very first round. Two threads calling `fork()` concurrently → one forked child never exits. The parent's `waitpid()` blocks forever.

This matches the AGENTS.md note: "Mutex is non-reentrant — child inherits locked state after fork() → deadlock". A global mutex in relibc (likely the memory allocator, CWD lock, or environ lock) is held by thread A when thread B calls `fork()`. Thread B's child inherits the locked mutex but thread A's copy doesn't exist in the child → deadlock.

### Why sequential fork works

The waitpid-stress tests 1-3 all fork from a single thread sequentially. 50 children, pipe I/O, concurrent exits — all pass. The issue is ONLY when two threads call fork() at the same time.

### Why JOBS=1 works

With JOBS=1, cargo only ever has one active compilation. It forks one rustc at a time, sequentially. No concurrent fork() calls.

### Why JOBS=2 single crate works

A single crate build only spawns one rustc process. Even with JOBS=2, there's only one unit of work. No concurrent fork() calls.

## Next Steps

1. **Identify the specific mutex** — read relibc fork() implementation to find which global lock causes the deadlock
2. **Fix option A**: Make fork() acquire all global locks before forking and release them in the child (pthread_atfork pattern)
3. **Fix option B**: Replace global mutexes with fork-safe alternatives (e.g., process-private locks that reset in child)
4. **Validate fix** with the test_concurrent_fork_exec test and the graduated workspace tests
