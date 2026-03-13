## ADDED Requirements

### Requirement: Instrumented kernel build for hang diagnosis
An instrumented kernel configuration SHALL be created that logs key events in `waitpid`, `pipe_read`/`pipe_write`, and context switching at a level sufficient to identify where threads stall during parallel cargo builds.

#### Scenario: Instrumented kernel boots and logs
- **WHEN** the Redox VM boots with the instrumented kernel
- **THEN** the serial console shows waitpid and pipe operation logs during process execution

#### Scenario: JOBS=2 cargo build produces diagnostic trace
- **WHEN** a cargo build runs with `CARGO_BUILD_JOBS=2` on the instrumented kernel
- **THEN** the serial log captures enough information to identify which process/thread is blocked and on what resource

### Requirement: Root cause documented
The investigation SHALL produce a documented root cause (or documented set of candidate causes with evidence) for the JOBS>1 hang. The documentation SHALL include: reproduction steps, kernel log analysis, and identification of the specific code path that stalls.

#### Scenario: Root cause report written
- **WHEN** the investigation completes
- **THEN** a report exists in the change directory documenting the root cause with evidence from kernel logs

#### Scenario: Known unknowns documented if root cause elusive
- **WHEN** the investigation cannot definitively identify the root cause within the allocated effort
- **THEN** the report documents what was ruled out (jobserver, fcntl, flock), what evidence points where, and what further investigation would be needed

### Requirement: JOBS>1 works or workaround hardened
If the root cause is fixable, parallel cargo builds with `CARGO_BUILD_JOBS=2` SHALL complete without hanging for at least a 50-crate project. If the root cause requires deep kernel changes beyond this cycle's scope, the `cargo-build-safe` timeout wrapper SHALL be hardened with better diagnostics.

#### Scenario: JOBS=2 builds 50 crates successfully
- **WHEN** a cargo project with 50+ crate dependencies is built with `CARGO_BUILD_JOBS=2`
- **THEN** the build completes without hanging

#### Scenario: Timeout wrapper improved if fix deferred
- **WHEN** the parallel hang cannot be fixed in this cycle
- **THEN** the `cargo-build-safe` wrapper logs which subprocess hung, its PID, and the stall duration before killing it

### Requirement: Self-hosting test updated for parallel builds
The self-hosting-test profile SHALL include a conditional parallel build test that runs with `CARGO_BUILD_JOBS=2` (in addition to the existing JOBS=1 tests). The test MUST have a timeout so it cannot hang the CI run.

#### Scenario: Parallel build test in self-hosting profile
- **WHEN** the self-hosting-test VM boots
- **THEN** it runs at least one cargo build with `CARGO_BUILD_JOBS=2` with a 10-minute timeout

#### Scenario: Parallel test does not block CI on failure
- **WHEN** the JOBS=2 build hangs
- **THEN** the test reports FAIL (not hang) after the timeout, and subsequent tests continue
