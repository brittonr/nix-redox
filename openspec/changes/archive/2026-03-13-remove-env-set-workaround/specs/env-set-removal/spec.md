## ADDED Requirements

### Requirement: Cargo builds without --env-set patch
The cargo build for Redox SHALL produce working binaries that can access `env!()` and `option_env!()` macro values without the `--env-set` CLI flag patch. Environment variables set via `Command::env()` in cargo's compilation module SHALL propagate through DSO-linked rustc to the `env!()` macro expansion.

#### Scenario: CARGO_PKG_NAME accessible via env!()
- **WHEN** a crate uses `env!("CARGO_PKG_NAME")` and is compiled by cargo without the `--env-set` patch
- **THEN** the macro expands to the correct package name at compile time

#### Scenario: OUT_DIR accessible via env!() in build-script-dependent crates
- **WHEN** a crate has a build script that sets env vars, and a dependent crate uses `env!("OUT_DIR")`
- **THEN** the OUT_DIR value propagates through DSO environ to rustc and the macro expands correctly

#### Scenario: option_env!() works for process environment variables
- **WHEN** a crate uses `option_env!("LD_LIBRARY_PATH")` and LD_LIBRARY_PATH is set in the process environment
- **THEN** the macro returns `Some(value)` with the correct value, confirming full environ propagation through DSOs

### Requirement: Self-hosting test suite passes without --env-set
All 62 self-hosting tests SHALL pass with the `--env-set` patch removed. No test regression is acceptable.

#### Scenario: Full test suite validation
- **WHEN** the self-hosting-test profile is built and run without `patch-cargo-env-set.patch`
- **THEN** all 62 tests report PASS, including env-propagation-simple, env-propagation-heavy, cargo-buildrs, and cargo-proc-macro

### Requirement: Test comments reflect actual env propagation mechanism
Test code and comments SHALL NOT reference `--env-set` as a mechanism for env!() working. Failure messages SHALL describe DSO environ propagation as the mechanism.

#### Scenario: No stale --env-set references in test output
- **WHEN** an env-propagation test fails
- **THEN** the failure message references DSO environ propagation, not `--env-set`

### Requirement: Documentation updated
AGENTS.md and napkin SHALL reflect that `--env-set` has been removed and DSO environ is the sole mechanism for env var propagation to rustc.

#### Scenario: Napkin updated
- **WHEN** reading the napkin's "Active Workarounds" section
- **THEN** the `--env-set` entry is moved to "Stale Claims" with a note that it was removed after DSO environ validation

#### Scenario: AGENTS.md updated
- **WHEN** reading AGENTS.md's self-hosting patches section
- **THEN** cargo patches list 3 (not 4), with `env-set` removed

## REMOVED Requirements

### Requirement: --env-set defense-in-depth for env!() macros
**Reason**: The root cause (DSO environ propagation) was fixed by `patch-relibc-environ-dso-init` and `patch-relibc-dso-environ`. The `--env-set` patch duplicated env vars through a second channel that is no longer needed. 62/62 tests validated the DSO fix under JOBS=2 load.
**Migration**: No migration needed. The DSO environ fix handles all env vars. Remove the patch file and its reference in `rustc-redox.nix`.
