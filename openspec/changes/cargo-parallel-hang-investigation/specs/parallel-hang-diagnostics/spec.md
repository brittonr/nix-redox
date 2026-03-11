## ADDED Requirements

### Requirement: Process state dumper captures blocked processes
The system SHALL provide a `proc-dump` binary that reads `/scheme/proc/` to list all running processes with their blocked/running state and open file descriptors. Output SHALL be written to a file (not stdout/stderr) to avoid perturbing pipe state.

#### Scenario: Dump all processes on timeout
- **WHEN** the parallel build test detects a hang (timeout exceeded)
- **THEN** `proc-dump` writes a snapshot of all process IDs, their states (blocked/running), and open scheme handles to `/tmp/proc-dump.log`

#### Scenario: Dump identifies blocked-on-pipe processes
- **WHEN** a process is blocked waiting on a pipe read or write
- **THEN** the dump output includes the scheme handle path (e.g., `pipe:3`) for that process's blocked file descriptor

### Requirement: Cargo job queue emits heartbeat diagnostics
The system SHALL patch cargo's `JobQueue` to emit periodic heartbeat lines to a log file showing: active jobs (with PIDs), jobs waiting for dependencies, and jobs waiting for jobserver tokens.

#### Scenario: Heartbeat during normal build
- **WHEN** cargo build runs with `CARGO_DIAG_LOG=/tmp/cargo-diag.log` set
- **THEN** cargo appends a status line every 5 seconds listing active job count, waiting job count, and pending token requests

#### Scenario: No heartbeat without env var
- **WHEN** cargo build runs without `CARGO_DIAG_LOG` set
- **THEN** no diagnostic heartbeat output is produced

#### Scenario: Heartbeat captures hang state
- **WHEN** cargo hangs waiting for a child process
- **THEN** the last heartbeat line in the log shows which job PID cargo is waiting for, allowing correlation with proc-dump output

### Requirement: Graduated workspace test finds hang threshold
The system SHALL extend the parallel-build-test profile with workspace sizes of 5, 10, 20, 50, and 100 crates, each built at JOBS=2 with a hard timeout. Each test emits FUNC_TEST result lines.

#### Scenario: Small workspace passes
- **WHEN** a 5-crate workspace builds at JOBS=2
- **THEN** the build completes within the timeout and emits `FUNC_TEST:parallel-jobs2-ws5:PASS`

#### Scenario: Large workspace triggers hang
- **WHEN** a workspace exceeding the hang threshold builds at JOBS=2
- **THEN** the test times out and emits `FUNC_TEST:parallel-jobs2-wsN:FAIL:timeout`

#### Scenario: Diagnostics captured on hang
- **WHEN** any workspace test times out
- **THEN** the test runs `proc-dump` and includes cargo diagnostic log contents in the test output before killing the build

### Requirement: Standalone waitpid stress test
The system SHALL include a test program that forks N children (configurable, default 50), each of which exits immediately, and verifies the parent collects all N exit notifications via `waitpid()`.

#### Scenario: All children collected with immediate exit
- **WHEN** 50 children are forked and each calls `_exit(0)` immediately
- **THEN** the parent collects exactly 50 WIFEXITED notifications and emits `FUNC_TEST:waitpid-stress-50:PASS`

#### Scenario: All children collected with pipe I/O before exit
- **WHEN** 50 children are forked, each writes 1KB to a pipe and then exits
- **THEN** the parent reads all pipe data and collects all 50 exit notifications without hanging

#### Scenario: Concurrent exits detected
- **WHEN** children are signaled to exit simultaneously (via pipe close)
- **THEN** the parent still collects all exit notifications within 10 seconds
