## Context

Cargo on Redox intermittently hangs during builds. The `cargo-build-safe` wrapper (90s timeout + kill + retry) was masking this. The assumption was that `flock()` was the hang source, but investigation revealed:

1. `flock()` is already a no-op in upstream relibc (`Sys::flock()` returns `Ok(())`)
2. `fcntl` locks are patched to no-op (`patch-relibc-fcntl-lock.patch`)
3. The real hang is in **process scheduling**: foreground process execution and bare `wait` both deadlock on KVM (Cloud Hypervisor), but not on QEMU TCG

The root cause: Redox's `waitpid` (via proc: scheme) hangs when the parent process is idle. Active polling with scheme I/O (`cat /scheme/sys/uname`) keeps the parent scheduled and prevents the hang. The old cargo-build-safe's polling loop (`kill -0 $PID` + scheme I/O) was accidentally the fix — the timeout and retry were unnecessary.

## Goals / Non-Goals

**Goals:**
- Replace the 30-line cargo-build-safe wrapper with a minimal 3-line polling pattern
- Remove timeout/retry/lockfile-cleanup logic (all unnecessary for the real bug)
- Validate all cargo builds pass on Cloud Hypervisor (KVM)

**Non-Goals:**
- Fixing the underlying Redox waitpid/proc: scheme bug (kernel change)
- Implementing real POSIX file locking (flock was never the issue)

## Decisions

### 1. Inline poll-wait pattern instead of wrapper script

**Choice:** Replace each `cargo-build-safe` call with an inline 3-line pattern:
```bash
cmd >/dev/null 2>/tmp/stderr &
PID=$!; while kill -0 $PID 2>/dev/null; do cat /scheme/sys/uname >/dev/null 2>/dev/null; done; wait $PID
EXIT=$?
```

**Why not a helper script:** Creating `/tmp/poll-wait` via printf+chmod caused exit code 126 (permission/execution issues) in some bash contexts on Redox. Inline patterns work reliably in all contexts.

**Why not foreground execution:** Foreground `cargo build` deadlocks on KVM. Bare `& wait $!` also deadlocks (even worse — hangs on the first cargo call instead of the second). Active polling is required.

### 2. Redirect stdout to /dev/null (or file)

**Choice:** All cargo build calls redirect stdout away from the serial console.

**Why:** Cargo writes nothing meaningful to stdout (progress goes to stderr). Redirecting stdout eliminates any possibility of serial write blocking contributing to the hang.

## Risks / Trade-offs

- **[Risk] Polling burns CPU cycles** → Acceptable: `cat /scheme/sys/uname` is a lightweight scheme read (~1ms), and it only runs while cargo is building.
- **[Risk] Root cause not fixed** → The Redox kernel's proc: scheme waitpid has a scheduling bug. This is a workaround, not a fix. Filed as known issue.
- **[Trade-off] 9 inline patterns vs 1 wrapper** → More lines in the test file, but each is self-contained and debuggable. The wrapper script approach failed (exit 126).
