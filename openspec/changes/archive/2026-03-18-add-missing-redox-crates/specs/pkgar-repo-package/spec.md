## ADDED Requirements

### Requirement: pkgar-repo builds as host tool
The build system SHALL build pkgar-repo natively for the host (Linux) from the existing `pkgar-src` flake input. pkgar-repo is a workspace member of the pkgar monorepo at `pkgar-repo/`. Dependencies: pkgar, pkgar-core, reqwest (blocking + rustls-tls). The ring crate SHALL be vendored from the Redox git fork, same as pkgutils.

#### Scenario: Successful pkgar-repo build
- **WHEN** `nix build .#pkgar-repo` is run
- **THEN** the output contains a native Linux binary for serving package repositories

#### Scenario: Ring crate vendored from git
- **WHEN** the vendor phase runs for pkgar-repo
- **THEN** the ring crate source comes from the `ring-redox-src` flake input

### Requirement: pkgar-repo exposed in flake
The pkgar-repo package SHALL be exposed as `packages.${system}.pkgar-repo` in the flake output.

#### Scenario: Flake package accessible
- **WHEN** `nix build .#pkgar-repo` completes
- **THEN** the derivation succeeds and the output store path contains a pkgar-repo binary
