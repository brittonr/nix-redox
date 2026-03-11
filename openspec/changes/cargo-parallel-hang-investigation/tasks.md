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

- [ ] 5.1 Write the fix patch targeting the identified root cause (relibc poll/waitpid/pipe or cargo job manager)
- [ ] 5.2 Add patch to the build pipeline (`nix/pkgs/system/patch-*.py` or `nix/pkgs/userspace/patch-*.py`)
- [ ] 5.3 Verify JOBS=1 still works (no regression) on self-hosting-test profile
- [ ] 5.4 Verify JOBS=2 workspace builds complete for all graduated sizes (5 through 100 crates)

## 6. Validation and Cleanup

- [ ] 6.1 Run parallel-build-test at JOBS=2 with 3-crate workspace — must pass within 120s
- [ ] 6.2 Run parallel-build-test at JOBS=2 with 20-crate workspace — must pass within 300s
- [ ] 6.3 Run parallel-build-test at JOBS=2 with 100-crate workspace — must pass within 600s
- [ ] 6.4 Update self-hosting-test and self-hosting profiles to set `CARGO_BUILD_JOBS=2`
- [ ] 6.5 Run snix self-compilation (193 crates) at JOBS=2 on self-hosting-test — must complete within 20 minutes
- [ ] 6.6 Update AGENTS.md: move JOBS>1 from "Active Workarounds" to fixed, document root cause and fix
- [ ] 6.7 Update napkin: mark JOBS>1 hang as resolved with root cause summary
