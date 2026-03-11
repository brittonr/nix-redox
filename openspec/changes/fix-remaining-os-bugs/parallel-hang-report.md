# Parallel Cargo Build Hang — Investigation Report

## Status: Initial Investigation

## Symptom
When `CARGO_BUILD_JOBS > 1`, cargo hangs indefinitely after compiling ~115-136 crates. The build progresses normally up to that point, then stops with all child processes blocked.

## What We Know

### Kernel implementation looks correct
The Redox kernel's context scheduler (`src/context/switch.rs`) properly handles:
- Context wakeup via `wake` timestamp (checked every ~6.75ms PIT tick)
- Round-robin scheduling with CPU affinity
- Blocked context states (soft-blocked and hard-blocked)

### nanosleep/clock_gettime work correctly
Confirmed via VM testing:
- `clock_gettime(CLOCK_MONOTONIC)` returns advancing values (HPET/PIT hardware)
- Timed waits (`read -t N`) complete in expected time
- The scheduler properly wakes sleeping contexts

### waitpid uses proc: scheme
On Redox, `waitpid` is implemented via `ProcCall::Waitpid` through the proc: scheme, not a direct kernel syscall. This adds scheme daemon IPC to the wait path.

### Existing workarounds
- `CARGO_BUILD_JOBS=1` — always works
- `cargo-build-safe` timeout wrapper with 90s retry — catches hangs
- `fcntl` locking patched to no-op (`patch-relibc-fcntl-lock.py`)

### What's been ruled out
- **Not a jobserver issue** — documented in AGENTS.md
- **Not fcntl file locking** — patched to no-op, still hangs
- **Not flock** — cargo-build-safe wrapper handles this case

## Theories

### 1. Pipe deadlock in process hierarchies
Cargo spawns rustc which spawns ld.lld. With JOBS>1, multiple rustc processes run simultaneously. Each has stdout/stderr pipes to cargo. If the pipe buffer fills and the reader (cargo) is blocked waiting for a different child, deadlock results.

Evidence: relibc's `poll()` is documented as "unreliable for pipe multiplexing" in AGENTS.md.

### 2. waitpid notification loss
The proc: scheme waitpid may lose notifications when multiple children exit simultaneously. If cargo calls waitpid for child A but child B exits first, and the notification for child B is consumed but not child A's, cargo blocks forever.

### 3. Thread starvation under memory pressure
With JOBS>1, more memory is consumed. The kernel may not schedule blocked contexts fairly when memory is tight.

### 4. Scheduler fairness
The round-robin scheduler in `update_runnable()` might not fairly wake contexts when many are soft-blocked with wake timers or waiting on scheme I/O.

## Next Steps

1. **Run parallel-build-test profile** with a small project (task 3.4)
2. **Add proc: scheme logging** for waitpid calls (which PID requested, which children exist)
3. **Add pipe buffer state logging** when read/write blocks
4. **Capture serial output** during a JOBS=2 hang
5. **Compare process tree** between working (JOBS=1) and hanging (JOBS=2) runs

## Created Files
- `nix/redox-system/profiles/parallel-build-test.nix` — test profile with JOBS=1 baseline and JOBS=2 test with hard timeout
