## 1. Diagnostic Tooling

- [x] 1.1 Write `proc-dump` Rust binary that reads `/scheme/proc/` to list all PIDs with blocked/running state and open file descriptors, output to a file path argument
- [x] 1.2 Package `proc-dump` as a Nix derivation cross-compiled for Redox and add to system packages
- [x] 1.3 Write `patch-cargo-heartbeat.py` that patches cargo's `JobQueue::drain_the_queue()` to emit periodic status lines (active jobs, waiting jobs, pending tokens) to `$CARGO_DIAG_LOG` file every 5 seconds
- [x] 1.4 Wire heartbeat patch into the cargo build pipeline alongside existing cargo patches

## 2. Waitpid Stress Test

- [x] 2.1 Write standalone Rust test binary that forks N children with immediate exit and verifies all N exit notifications collected via waitpid
- [x] 2.2 Add variant that has children write 1KB to a pipe before exiting, parent reads all pipe data and collects all exits
- [x] 2.3 Add variant with concurrent exits (children block on pipe, parent closes pipe to trigger simultaneous exit)
- [x] 2.4 Package waitpid stress test for Redox and add to parallel-build-test profile

## 3. Graduated Workspace Tests

- [x] 3.1 Extend parallel-build-test.nix to generate workspaces of 5, 10, 20, 50, and 100 crates with inter-crate dependencies
- [x] 3.2 Each workspace test runs at JOBS=2 with timeout (120s for ≤10, 300s for ≤50, 600s for 100), emits FUNC_TEST result lines
- [x] 3.3 On timeout, run `proc-dump` and dump cargo diagnostic log contents before killing the build
- [x] 3.4 Build and run the graduated test in VM to find the exact hang threshold

## 4. Root Cause Analysis

- [x] 4.1 Analyze proc-dump and cargo heartbeat logs from the first hanging workspace size to identify: which process is stuck, what it's waiting on, and whether waitpid/pipe/jobserver is the blocked path
- [x] 4.2 Cross-reference waitpid stress test results — if waitpid drops notifications, the bug is in proc: scheme or relibc waitpid wrapper
- [x] 4.3 Write concurrent fork+exec test: two threads each fork+exec a trivial program simultaneously — CONFIRMED HANG: test_concurrent_fork_exec hangs on first round, proving relibc fork() is not thread-safe
- [x] 4.4 Document root cause findings in the parallel-hang-report.md

## 5. Fix Implementation

- [x] 5.1 Done: `patch-relibc-fork-lock.py` — yield-based AtomicI32 RW lock replacing futex-based CLONE_LOCK
- [x] 5.2 Done: patch wired into `nix/pkgs/system/patch-relibc-fork-lock.py`
- [x] 5.3 Done: self-hosting-test 62/62 PASS (2026-03-13), JOBS=2 throughout
- [x] 5.4 Done: parallel-build-test 12/12 PASS including ws5/10/20/50/100 at JOBS=2

## 6. Validation and Cleanup

- [x] 6.1 Done: parallel-build-test ws5 PASS (2026-03-12)
- [x] 6.2 Done: parallel-build-test ws20 PASS (2026-03-12)
- [x] 6.3 Done: parallel-build-test ws100 PASS in 240s (2026-03-12)
- [x] 6.4 Done: self-hosting-test uses CARGO_BUILD_JOBS=2 throughout, self-hosting uses CARGO_BUILD_JOBS=4
- [x] 6.5 Done: snix self-compilation (193 crates) at JOBS=2 passes as part of self-hosting-test (snix-compile test)
- [x] 6.6 Done: AGENTS.md documents fork-lock fix, CLONE_LOCK root cause, yield-based replacement
- [x] 6.7 Done: napkin has "JOBS>1 parallel cargo builds (FIXED 2026-03-12)" entry
