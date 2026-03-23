## ADDED Requirements

### Requirement: Pin updated to latest upstream canon
The `snix-upstream-source.nix` derivation SHALL fetch upstream snix at a commit from 2026-03-19 or later on the canon branch.

#### Scenario: Fetched commit is recent
- **WHEN** the `snix-upstream-source` derivation is built
- **THEN** the `rev` field in `fetchgit` references a commit dated 2026-03-19 or later

#### Scenario: Hash matches the new commit
- **WHEN** the `snix-upstream-source` derivation is built
- **THEN** the `hash` field in `fetchgit` produces a successful fixed-output derivation (no hash mismatch)

### Requirement: All extraction patches re-verified against new source
Each sed transform and patch in `snix-upstream-source.nix` SHALL still apply correctly against the new upstream source. Transforms that are no longer needed (because upstream made the same change) SHALL be removed.

#### Scenario: FUSE feature removal from snix-build
- **WHEN** the derivation is built
- **THEN** `build/Cargo.toml` does not list `fuse` in the snix-castore dependency features

#### Scenario: bwrap/oci gating behind linux-sandbox feature
- **WHEN** the derivation is built
- **THEN** `build/src/lib.rs` and `build/src/buildservice/mod.rs` gate bwrap/oci modules with `cfg(all(target_os = "linux", feature = "linux-sandbox"))`

#### Scenario: Cloud disabled in snix-castore defaults
- **WHEN** the derivation is built
- **THEN** `castore/Cargo.toml` has `default = []` (not `default = ["cloud"]`)

#### Scenario: snix-store defaults stripped
- **WHEN** the derivation is built
- **THEN** `store/Cargo.toml` has `default = []` (no cloud, fuse, otlp, or tonic-reflection)

#### Scenario: tonic uses ring TLS backend
- **WHEN** the derivation is built
- **THEN** `store/Cargo.toml` references `tls-ring` (not `tls-aws-lc`) in tonic features

#### Scenario: Redox systems patch applied
- **WHEN** the derivation is built
- **THEN** `eval/src/systems.rs` contains `"redox"` in the `is_second_coordinate()` match

#### Scenario: Obsolete transforms removed
- **WHEN** an upstream change already makes one of our seds a no-op
- **THEN** that sed line SHALL be removed from `snix-upstream-source.nix` and a comment notes why

### Requirement: Workspace dependency versions synchronized
The `[workspace.dependencies]` in `snix-redox/Cargo.toml` SHALL match the versions declared in upstream snix's root `Cargo.toml` at the pinned commit, plus any Redox-specific overrides (e.g., rustls ring backend).

#### Scenario: Upstream crate versions match
- **WHEN** `snix-redox/Cargo.toml` is compared to upstream's workspace dependencies
- **THEN** all shared dependency versions match (except for explicitly documented Redox overrides like `rustls`)

#### Scenario: New upstream workspace deps added
- **WHEN** upstream added a new workspace dependency that our extracted crates use
- **THEN** that dependency is present in our `[workspace.dependencies]` at the correct version

### Requirement: snix-redox compiles against updated upstream
All `snix-redox` source files SHALL compile without errors against the updated upstream crate APIs.

#### Scenario: Host-side compilation
- **WHEN** `cargo check` is run in the snix-redox workspace
- **THEN** compilation succeeds with zero errors

#### Scenario: Cross-compilation to Redox
- **WHEN** `nix build .#snix-redox` is run
- **THEN** the build succeeds and produces a `snix` binary for x86_64-unknown-redox

### Requirement: Test suite passes
The full snix-redox test suite SHALL pass after the version bump with no new failures.

#### Scenario: All host-side tests pass
- **WHEN** `cargo test` is run in the snix-redox workspace
- **THEN** all 562+ tests pass (no regressions)

### Requirement: Vendor hashes updated
The vendor hashes in `snix.nix` and `snix-source-bundle.nix` SHALL be updated to reflect any dependency version changes.

#### Scenario: snix.nix builds successfully
- **WHEN** `nix build .#snix-redox` is run
- **THEN** vendor fetching succeeds (no hash mismatch)

#### Scenario: Source bundle builds successfully
- **WHEN** `nix build .#snix-source-bundle` is run (if it exists)
- **THEN** vendor fetching succeeds (no hash mismatch)
