## ADDED Requirements

### Requirement: flock returns success immediately
The `flock()` function in relibc SHALL return `Ok(0)` for all operation values (LOCK_SH, LOCK_EX, LOCK_UN, and their LOCK_NB combinations) without forwarding the call to the Redox kernel.

#### Scenario: Exclusive lock does not block
- **WHEN** a process calls `flock(fd, LOCK_EX)` on any open file descriptor
- **THEN** the call returns 0 (success) immediately without blocking

#### Scenario: Shared lock does not block
- **WHEN** a process calls `flock(fd, LOCK_SH)` on any open file descriptor
- **THEN** the call returns 0 (success) immediately without blocking

#### Scenario: Non-blocking lock succeeds
- **WHEN** a process calls `flock(fd, LOCK_EX | LOCK_NB)` on any open file descriptor
- **THEN** the call returns 0 (success) immediately (never returns EWOULDBLOCK)

#### Scenario: Unlock succeeds
- **WHEN** a process calls `flock(fd, LOCK_UN)` on any open file descriptor
- **THEN** the call returns 0 (success) immediately

### Requirement: cargo builds without timeout wrapper
All cargo invocations in the self-hosting test profile SHALL use direct `cargo build` calls. The `cargo-build-safe` timeout wrapper SHALL be removed.

#### Scenario: Self-hosting tests pass without wrapper
- **WHEN** the self-hosting test suite runs with the flock no-op patch applied and cargo-build-safe removed
- **THEN** all 62 tests report PASS with no timeout-related failures

#### Scenario: No cargo-build-safe references remain
- **WHEN** `self-hosting-test.nix` is searched for `cargo-build-safe`
- **THEN** zero matches are found
