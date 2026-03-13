## ADDED Requirements

### Requirement: JOBS=2 workspace builds complete without hanging
Cargo SHALL complete a workspace build with `CARGO_BUILD_JOBS=2` on Redox OS without hanging, for workspaces up to 100 crates.

#### Scenario: 3-crate workspace at JOBS=2
- **WHEN** a 3-crate workspace is built with `CARGO_BUILD_JOBS=2` on Redox
- **THEN** the build completes successfully within 120 seconds

#### Scenario: 20-crate workspace at JOBS=2
- **WHEN** a 20-crate workspace with inter-crate dependencies is built with `CARGO_BUILD_JOBS=2` on Redox
- **THEN** the build completes successfully within 300 seconds

#### Scenario: 100-crate workspace at JOBS=2
- **WHEN** a 100-crate workspace is built with `CARGO_BUILD_JOBS=2` on Redox
- **THEN** the build completes successfully within 600 seconds

### Requirement: Root cause fix applied to relibc or cargo
The identified root cause SHALL be fixed via a patch to relibc, cargo, or both. The patch SHALL be added to the existing patch pipeline (`nix/pkgs/system/patch-*.py` or `nix/pkgs/userspace/patch-*.py`).

#### Scenario: Fix integrated into build system
- **WHEN** the Redox system image is built with the fix patch
- **THEN** the patch applies cleanly and the system boots normally

#### Scenario: Fix does not regress JOBS=1
- **WHEN** any build that worked at JOBS=1 is run after the fix
- **THEN** it still completes successfully at JOBS=1

### Requirement: Self-hosting profiles updated for JOBS=2
The self-hosting and self-hosting-test profiles SHALL set `CARGO_BUILD_JOBS=2` (up from 1) once the fix is validated.

#### Scenario: self-hosting-test uses JOBS=2
- **WHEN** the self-hosting-test VM boots and runs its cargo build tests
- **THEN** `CARGO_BUILD_JOBS` is set to 2 and all builds complete without the cargo-build-safe timeout firing

#### Scenario: snix self-compilation at JOBS=2
- **WHEN** snix (193 crates) is self-compiled on Redox with JOBS=2
- **THEN** the build completes without hanging (timeout threshold: 20 minutes)

### Requirement: AGENTS.md and napkin updated with findings
The investigation findings SHALL be documented: root cause, fix description, and any remaining limitations (e.g., JOBS > 2 untested).

#### Scenario: Root cause documented
- **WHEN** the fix is validated
- **THEN** AGENTS.md contains the root cause description under the appropriate section and the napkin's "JOBS>1 still hangs" entry is updated to reflect the fix
