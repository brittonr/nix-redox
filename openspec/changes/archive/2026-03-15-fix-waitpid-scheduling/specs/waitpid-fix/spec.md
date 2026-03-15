## ADDED Requirements

### Requirement: Foreground wait completes without active polling

A parent process that calls `waitpid()` (or the equivalent `wait` shell builtin) SHALL be woken when the child exits, without requiring the parent to perform unrelated scheme I/O to trigger a scheduler context switch.

#### Scenario: Shell wait on a single child
- **WHEN** a shell script runs `cmd & PID=$!; wait $PID` where `cmd` exits after 1 second
- **THEN** the shell's `wait` returns within 2 seconds with the child's exit code

#### Scenario: Shell wait without scheme I/O polling
- **WHEN** a shell script runs `cmd &; wait $!` with no concurrent `cat /scheme/sys/uname` loop
- **THEN** `wait` completes and does not deadlock

#### Scenario: C program using waitpid blocks and wakes
- **WHEN** a C program calls `fork()`, the child calls `_exit(42)`, and the parent calls `waitpid(child_pid, &status, 0)`
- **THEN** the parent's `waitpid` returns with `WIFEXITED(status)` true and `WEXITSTATUS(status) == 42`

#### Scenario: Rust Command::status completes
- **WHEN** a Rust program calls `Command::new("true").status()`
- **THEN** the call returns `Ok` with exit code 0, without hanging

### Requirement: SQE delivery wakes scheme daemons

When the kernel enqueues an SQE on a userspace scheme's socket (e.g., the procmgr's proc: scheme), the scheme daemon SHALL be woken from its event wait within one scheduler tick, regardless of whether the daemon's vCPU is idle.

#### Scenario: SQE wakes procmgr from event wait
- **WHEN** a process calls `waitpid()`, relibc sends `SYS_CALL`, and the kernel enqueues an SQE on the procmgr's scheme socket
- **THEN** the procmgr's `next_event()` call returns with the SQE within one scheduler tick

#### Scenario: SQE delivery wakes HLT'd vCPU on KVM
- **WHEN** the system runs under KVM (Cloud Hypervisor) and the procmgr's vCPU has executed HLT
- **THEN** the SQE enqueue triggers a vCPU exit from HLT and the scheduler runs the procmgr

#### Scenario: Multiple concurrent SQEs processed
- **WHEN** two processes call `waitpid()` simultaneously, generating two SQEs for the procmgr
- **THEN** the procmgr processes both SQEs and returns CQEs for both callers

### Requirement: Procmgr event loop remains responsive

The procmgr's single-threaded event loop SHALL process SQEs without starvation, regardless of system idle state or vCPU scheduling.

#### Scenario: Procmgr processes waitpid during idle system
- **WHEN** the system has been idle for 5 seconds and a process calls `waitpid()`
- **THEN** the procmgr receives and processes the SQE within one scheduler tick

#### Scenario: Procmgr handles burst of requests
- **WHEN** 50 processes call `waitpid()` in rapid succession
- **THEN** the procmgr processes all 50 SQEs and all callers receive their CQEs

### Requirement: Poll-wait workarounds removed from scripts

After the kernel fix, all poll-wait patterns (`cmd & PID=$!; while kill -0 $PID; do cat /scheme/sys/uname; done; wait $PID`) SHALL be replaced with plain `cmd & PID=$!; wait $PID` or direct foreground execution.

#### Scenario: self-hosting-test.nix uses plain wait
- **WHEN** the self-hosting test profile invokes cargo or other long-running commands
- **THEN** no `while kill -0` polling loops exist in the profile — commands use `wait $PID` or run in foreground

#### Scenario: build-ripgrep.sh uses plain wait
- **WHEN** `build-ripgrep.sh` runs cargo build
- **THEN** the script backgrounds cargo only for timeout control, not for poll-wait scheduling workarounds

#### Scenario: Builds complete without hangs after removal
- **WHEN** the self-hosting test runs a full cargo build (ripgrep, JOBS=2) with workarounds removed
- **THEN** the build completes within its timeout without deadlocking

### Requirement: Pipe-based process output collection works for deep hierarchies

After the root cause is fixed, `Command::output()` (which creates pipes and uses `read2` internally) SHALL work for process trees at least 5 levels deep (builder→cargo→rustc→cc→lld) without crashes or hangs.

#### Scenario: snix builder uses cmd.output()
- **WHEN** snix's `local_build.rs` uses `cmd.output()` instead of `Stdio::inherit()` + `status()`
- **THEN** the builder captures stderr, the build completes, and no pipe-related crashes occur

#### Scenario: Deep hierarchy pipe cleanup
- **WHEN** a 5-level process tree (parent→A→B→C→D) exits from the leaves up
- **THEN** pipe close events propagate correctly and the root parent's `read2` returns without entering an unrecoverable state

#### Scenario: Fallback if pipe issue is independent
- **WHEN** the waitpid fix is applied but `cmd.output()` still crashes on deep hierarchies
- **THEN** the `Stdio::inherit()` workaround in snix is retained and documented as a separate issue
