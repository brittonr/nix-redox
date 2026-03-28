## ADDED Requirements

### Requirement: Bootstrap builds with current relibc deps
The bootstrap binary must compile against the current relibc-src flake input, including any transitive dependency changes (e.g., goblin version bumps).

#### Scenario: Bootstrap Cargo.lock matches relibc deps
- **WHEN** relibc-src updates its Cargo.toml dependencies
- **THEN** the bootstrap Cargo.lock in the repo contains matching dependency versions
- **AND** `nix build .#packages.x86_64-linux.bootstrap` succeeds

#### Scenario: Lockfile regen procedure is documented
- **WHEN** a developer runs `nix flake update relibc-src`
- **THEN** a comment in bootstrap.nix explains how to regenerate the lockfile
- **AND** the procedure can be run without network access to the Nix daemon

### Requirement: Bootstrap vendor contains all resolved deps
The fetchCargoVendor output must include all crates referenced by the bootstrap Cargo.lock, including transitive deps from relibc path dependencies.

#### Scenario: Vendor hash is valid
- **WHEN** the checked-in Cargo.lock is updated
- **THEN** the vendor hash in bootstrap.nix is updated to match
- **AND** no "no matching package" errors occur during bootstrap build
