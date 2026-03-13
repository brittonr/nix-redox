## ADDED Requirements

### Requirement: parallel-jobs2-self-hosting-pass
The self-hosting test's `parallel-jobs2` test must PASS with `CARGO_BUILD_JOBS=2` using the cc wrapper linker path (`linker = "/nix/system/profile/bin/cc"`).

#### Scenario: parallel-jobs2 builds a single crate at JOBS=2
- **WHEN** `cargo build --offline -j2` runs with `linker = cc` in cargo config
- **THEN** the build completes with exit code 0 and emits `FUNC_TEST:parallel-jobs2:PASS`

### Requirement: full-self-hosting-test-at-jobs2
All self-hosting test functions that use `CARGO_BUILD_JOBS=2` must pass, including snix self-compilation (193 crates) and ripgrep compilation.

#### Scenario: self-hosting-test runs end-to-end
- **WHEN** `nix run .#self-hosting-test` completes
- **THEN** `parallel-jobs2` is PASS and no JOBS=2 builds produce `abort()` or `failed to initiate panic` errors

### Requirement: investigation-changes-archived
The `cargo-parallel-hang-investigation` and `fix-remaining-os-bugs` changes are archived with sync notes explaining which tasks were completed vs deferred.

#### Scenario: archive completed
- **WHEN** both changes are moved to `openspec/changes/archive/`
- **THEN** delta specs are synced to main specs and archive directories contain the original change files

### Requirement: documentation-accurate
AGENTS.md and napkin reflect the actual parallel build state — no stale claims about lld stack or CLONE_LOCK.

#### Scenario: napkin parallel-jobs2 entry updated
- **WHEN** the crash is diagnosed and fixed (or confirmed already fixed)
- **THEN** the napkin entry for "Self-hosting test parallel-jobs2 linker crash" is updated or moved to stale claims
