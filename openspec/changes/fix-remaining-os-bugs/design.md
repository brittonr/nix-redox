## Context

Redox OS can self-host Rust compilation (single-threaded cargo builds, proc-macro crates, snix derivations) but three OS-level bugs limit reliability and throughput:

1. **nanosleep hangs forever**: relibc's `nanosleep()` never returns on Redox. Programs calling `sleep()`, `usleep()`, or `std::thread::sleep()` block indefinitely. The Redox kernel exposes time via `/scheme/time` — relibc needs to use scheme I/O instead of a raw syscall that doesn't exist.

2. **DSO environ not propagated**: Each dynamically-linked shared library gets its own copy of relibc's `environ` static, initialized to the process's original environment. When Rust's `Command::env()` updates the global `environ` pointer before `exec()`, the update doesn't reach relibc's internal copy used by `execv()`. The ld.so already injects `ns_fd`, `proc_fd`, and `CWD` into DSOs — `environ` needs the same treatment.

3. **Parallel cargo hangs at JOBS>1**: After ~115-136 crates, cargo compilation with `CARGO_BUILD_JOBS > 1` hangs indefinitely. Theories include waitpid notification loss, pipe deadlock in deep process hierarchies, thread starvation, or scheduler bugs. No root cause identified yet.

Current workarounds: `--env-set` flag for every cargo invocation (permanent), `JOBS=1` (permanent), `cargo-build-safe` timeout wrapper with 90s retry.

## Goals / Non-Goals

**Goals:**
- `sleep 1` completes in ~1 second on Redox
- `std::thread::sleep(Duration::from_secs(1))` works in Rust programs
- `Command::new("child").env("FOO", "bar")` propagates FOO to dynamically-linked children
- Remove the `--env-set` workaround from cargo patches
- Identify root cause of JOBS>1 hang and fix it, or document the root cause with a targeted workaround
- All fixes delivered as relibc patch scripts following the existing `patch-relibc-*.py` pattern

**Non-Goals:**
- High-resolution timers or POSIX timer_create/timer_settime
- Full POSIX signal semantics (SIGALRM, itimers)
- Fixing all relibc POSIX gaps (openat, unlinkat, etc.)
- Making cargo JOBS=N work for arbitrarily large N — even JOBS=2 or JOBS=4 would be a win
- Kernel scheduler rewrite

## Decisions

### D1: nanosleep via time scheme reads

**Decision**: Implement `nanosleep()` by opening `/scheme/time/<monotonic-or-realtime>` and performing a blocking read with a timeout calculated from the requested sleep duration.

**Rationale**: Redox has no `SYS_NANOSLEEP` syscall. The kernel exposes time through the `time:` scheme daemon. Reading from a time scheme handle with a deadline is the idiomatic Redox approach (how `sleep` would work if it existed). The `clock_gettime()` function already reads from `/scheme/time/monotonic` — nanosleep just needs to block until the target timestamp.

**Alternative considered**: Busy-loop polling `clock_gettime()` — wastes CPU, unusable for real programs.

**Alternative considered**: Adding a `SYS_NANOSLEEP` kernel syscall — larger kernel change, goes against Redox's microkernel philosophy of scheme-based I/O.

### D2: environ injection via ld.so init

**Decision**: Add `__relibc_init_environ` static to each DSO (same pattern as `__relibc_init_ns_fd`/`__relibc_init_proc_fd`/`__relibc_init_cwd_ptr`) and have `ld_so::run_init()` write the parent's `environ` pointer into each loaded DSO before calling `.init_array`.

**Rationale**: The injection pattern is proven — three other statics already use it. The ld.so runs before any DSO code executes, so environ is available everywhere from the start. Rust's `Command::env()` modifies the `environ` pointer before exec, and if exec re-runs ld.so (as it does), the new environ is picked up.

**Alternative considered**: Making `environ` a single shared global across all DSOs — requires changes to how relibc links, risks breaking the existing per-DSO static model that works for other things.

### D3: Parallel hang investigation strategy

**Decision**: Add instrumentation before attempting a fix. Insert logging at key points in the kernel's `waitpid`, `pipe_read`/`pipe_write`, and scheduler `switch_to` paths. Run a JOBS=2 cargo build with the instrumented kernel and capture where threads stall.

**Rationale**: Without knowing the root cause, any fix is a guess. The three leading theories (waitpid notification loss, pipe deadlock, scheduler starvation) each require different fixes. Instrumented builds are how the chdir deadlock and ld.so CWD bugs were found previously.

**Alternative considered**: Just use JOBS=1 permanently — acceptable if investigation shows the fix requires deep kernel refactoring, but worth at least identifying the cause.

### D4: Patch delivery as Python scripts

**Decision**: Each fix is a Python patch script (`patch-relibc-nanosleep.py`, `patch-relibc-environ-dso.py`) invoked during the Nix build, matching the existing 10+ relibc patch scripts.

**Rationale**: Consistent with the project's established pattern. Patches are isolated, auditable, and can be individually removed when upstream relibc merges fixes.

## Risks / Trade-offs

- **[Risk] nanosleep scheme path may not support blocking reads with timeout** → Mitigation: Fall back to a poll loop with exponential backoff on `clock_gettime()` if scheme-based blocking isn't viable. Even a poll loop that actually returns would be an improvement over hanging.

- **[Risk] environ injection may break programs that intentionally modify environ after exec** → Mitigation: The injection happens once at DSO load time. Subsequent `setenv()`/`putenv()` calls modify the same pointer. Test with cargo (proc-macros), rustc, and basic setenv/getenv round-trips.

- **[Risk] Parallel hang root cause may be in the kernel, requiring kernel patches we can't deliver via relibc patches** → Mitigation: The investigation task is explicitly separated from the fix. If the root cause is in the kernel, document it and keep JOBS=1 as the workaround. Partial progress (JOBS=2 working) is still valuable.

- **[Risk] Removing --env-set before DSO environ is fully validated could break self-hosting** → Mitigation: Keep --env-set as a fallback behind a flag. Only remove it after the self-hosting test passes without it.

- **[Trade-off] nanosleep via scheme read adds per-sleep syscall overhead** → Acceptable. Sleep is not a hot path. Correctness matters more than latency for sleep calls.
