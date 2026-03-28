## ADDED Requirements

### Requirement: Pin updated to upstream commit 34604636d7
The snix upstream source derivation SHALL fetch commit `34604636d7` from the snix canon branch. The fetchgit hash SHALL match the actual content at that revision.

#### Scenario: Source derivation builds with new pin
- **WHEN** `nix build .#snix` is invoked
- **THEN** the snix-upstream-source derivation fetches the correct commit and all Redox patches apply without error

### Requirement: Redox patches apply cleanly on new upstream
All existing sed-based patches in `snix-upstream-source.nix` SHALL apply without error on the new upstream code. The patches cover: eval systems.rs (redox coordinate), glue pub visibility (derivation_into_build_request, fetchurl module/function/error), build/castore/store feature gating, and build bwrap/oci cfg gating.

#### Scenario: Systems patch applies
- **WHEN** the eval/src/systems.rs patch is applied
- **THEN** `is_second_coordinate` includes `"redox"` in the match list

#### Scenario: Glue visibility patches apply
- **WHEN** the glue sed commands run
- **THEN** `derivation_into_build_request` is `pub fn`, `fetchurl` module is `pub mod`, and `fetchurl_derivation_to_fetch` and `Error` are `pub`

#### Scenario: Feature default overrides apply
- **WHEN** the castore and store default feature sed commands run
- **THEN** castore defaults are `[]` and store defaults are `[]`

### Requirement: Workspace dependency versions synchronized
The `[workspace.dependencies]` section in `snix-redox/Cargo.toml` SHALL reflect the upstream workspace dependency versions at the pinned commit. The comment referencing the upstream commit hash SHALL be updated.

#### Scenario: No version drift
- **WHEN** upstream workspace dependencies are compared to snix-redox Cargo.toml
- **THEN** all shared dependency versions match

### Requirement: Host-side tests pass
`nix flake check` SHALL pass with the updated pin, confirming that snix-redox compiles and all host-side tests succeed.

#### Scenario: Flake check passes
- **WHEN** `nix flake check` is run
- **THEN** all checks pass (clippy, nextest, build)

### Requirement: VM functional tests pass
The standard VM functional test suite SHALL pass with the updated snix binary, confirming no regressions in on-Redox eval, build, fetch, and store operations.

#### Scenario: VM tests pass
- **WHEN** the VM functional test profile boots and runs test scripts
- **THEN** all functional tests report PASS
