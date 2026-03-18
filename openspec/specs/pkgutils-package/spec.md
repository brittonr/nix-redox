## ADDED Requirements

### Requirement: pkgutils builds for Redox target
The build system SHALL cross-compile pkgutils from `pkgutils-src` flake input, producing a `pkg` binary for `x86_64-unknown-redox`. The ring crate SHALL be vendored from the Redox git fork (`redox-os/ring.git` branch `redox-0.17.8`) instead of crates.io.

#### Scenario: Successful pkgutils build
- **WHEN** `nix build .#pkgutils` is run
- **THEN** the output contains `bin/pkg` as an ELF binary for x86_64-unknown-redox

#### Scenario: Ring crate vendored from git
- **WHEN** the vendor phase runs for pkgutils
- **THEN** the ring crate source comes from the `ring-redox-src` flake input with pregenerated assembly files present

### Requirement: pkgutils available in development profile
The development profile SHALL include pkgutils in system packages so the `pkg` command is available on boot.

#### Scenario: pkg command available after boot
- **WHEN** a Redox system boots with the development profile
- **THEN** `/bin/pkg` exists and is executable

### Requirement: pkgutils package exposed in flake
The pkgutils package SHALL be exposed as `packages.${system}.pkgutils` in the flake output.

#### Scenario: Flake package accessible
- **WHEN** `nix build .#pkgutils` completes
- **THEN** the derivation succeeds and the output store path contains `bin/pkg`
