## Why

Three categories of OS-level bugs block Redox from running multi-crate cargo builds reliably and supporting standard POSIX timing. The nanosleep/clock bug makes `sleep` unusable and breaks any program relying on `Instant::now()` advancing. The DSO environ bug forces a permanent `--env-set` workaround for every proc-macro crate. The parallel compilation hang at JOBS>1 caps build throughput to a single core. Fixing these removes the last major reliability barriers for self-hosted Rust development on Redox.

## What Changes

- **Fix `nanosleep()` in relibc** so that `sleep`, `usleep`, and `std::thread::sleep` work. The current implementation hangs forever because the Redox kernel's time scheme interaction is broken or the syscall path is incomplete. This unblocks any program that needs timed waits, polling loops, or timeouts.
- **Fix DSO environ propagation** so that environment variables set via `Command::env()` reach dynamically-linked child processes. Each DSO gets its own copy of relibc's `environ` static; the ld.so needs to propagate the parent's environ pointer into all loaded DSOs at exec time, similar to the existing ns_fd/proc_fd/CWD injection.
- **Diagnose and fix the parallel cargo hang** that occurs after ~115-136 crates when `CARGO_BUILD_JOBS > 1`. Root cause is unknown — candidates include waitpid notification loss, pipe deadlock in process hierarchies, thread starvation under memory pressure, or a scheduler bug. This task requires instrumented builds and kernel-level investigation.
- **Remove the cargo-build-safe timeout wrapper** once flock/hang issues are resolved, or harden it if the underlying bugs cannot be fixed in this cycle.

## Capabilities

### New Capabilities
- `relibc-nanosleep`: Fix the nanosleep/clock_nanosleep implementation so timed sleeps complete instead of hanging. Covers sleep, usleep, nanosleep, clock_gettime monotonic advancement.
- `dso-environ-propagation`: Fix environment variable propagation through exec for DSO-linked binaries. Covers ld.so environ injection, removal of --env-set workaround.
- `parallel-cargo-builds`: Diagnose and fix the JOBS>1 hang during multi-crate cargo compilation. Covers waitpid, pipe handling, scheduler fairness under cargo's process hierarchy.

### Modified Capabilities

(none — these are OS-level fixes below the spec boundary of existing store/profile/sandbox capabilities)

## Impact

- **relibc**: Patches to `src/platform/redox/` for nanosleep, environ, and possibly signal handling.
- **ld.so**: New `__relibc_init_environ` injection path mirroring existing ns_fd/proc_fd/CWD pattern.
- **Kernel**: Possible fixes to time scheme, waitpid notification, or scheduler if parallel hang traces there.
- **Nix build system**: New patch scripts (`patch-relibc-nanosleep.py`, `patch-relibc-environ-dso.py`). Existing `patch-cargo-env-set.py` can be removed once DSO environ works.
- **Test profiles**: `self-hosting-test.nix` updated to test JOBS>1 and remove timeout wrapper. New `functional-test.nix` tests for sleep and environ propagation.
- **AGENTS.md / napkin.md**: Active bugs and workaround sections updated as fixes land.
