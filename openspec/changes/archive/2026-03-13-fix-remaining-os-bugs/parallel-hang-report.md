# Parallel Cargo Build Hang — Investigation Report

## Status: Root Cause Narrowed (2026-03-11)

## Symptom
When `CARGO_BUILD_JOBS > 1`:
- **Simple crates (hello-world)**: The linker (`cc`/`lld`) crashes with `fatal runtime error: failed to initiate panic, error 0, aborting` / `relibc: abort() called`. Exit code 101. Cargo reports `error: linking with 'cc' failed: exit status: 1`.
- **Large projects (~115-136 crates)**: Build hangs indefinitely (may be a different manifestation or a related issue where the crash causes cargo to wait forever for the dead child).

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

## Key Finding (2026-03-11)

The JOBS=2 crash is in the **linker process**, not cargo or rustc. The error trace:
```
error: linking with `cc` failed: exit status: 1
  = note: "cc" "-m64" ... "-static" "-no-pie" ... "-nodefaultlibs"
  = note:
fatal runtime error: failed to initiate panic, error 0, aborting
relibc: abort() called
```

This crash occurs even for a trivial `fn main() { println!("hello"); }` project. JOBS=1 works because only one `cc`/`lld` runs at a time. With JOBS=2, two linker invocations run concurrently and at least one crashes.

## Leading Theories (Updated)

### 1. Stack overflow in lld (MOST LIKELY)
The Redox kernel gives main threads ~8KB of stack. `patch-rustc-main-stack.py` grows rustc's stack to 16MB by spawning a thread, but this patch does NOT apply to the `cc` wrapper or `lld`. When two `lld` instances run concurrently, memory pressure may reduce available stack, causing one to overflow and triggering the `failed to initiate panic` error (which fires when the panic handler itself can't run — classic stack overflow symptom).

### 2. Concurrent process resource exhaustion
Two simultaneous `cc` → `lld` invocations may exhaust a shared OS resource (file descriptors, memory mappings, pipe buffers). One process gets an error, tries to panic, but the panic handler fails due to the same resource constraint.

### 3. DSO environ / ld.so initialization race
Multiple concurrent `lld` processes may race on ld.so initialization of DSO statics, corrupting the runtime state and causing a crash in the panic handler.

## Next Steps

1. **Apply the main-stack growth patch to the `cc` wrapper** — spawn lld in a thread with larger stack
2. **Add stack size check** — print main thread stack size from lld to serial before linking
3. **Test JOBS=2 with stack-grown lld** — if it passes, stack overflow is confirmed
4. If stack overflow is NOT the cause, add strace to the linker invocation to see what syscall fails

## Created Files
- `nix/redox-system/profiles/parallel-build-test.nix` — test profile with JOBS=1 baseline and JOBS=2 test with hard timeout
