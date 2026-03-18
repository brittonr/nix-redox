## ADDED Requirements

### Requirement: redoxer builds as host tool
The build system SHALL build redoxer natively for the host (Linux) from `redoxer-src` flake input. Redoxer is the canonical tool for running Redox programs from a Linux KVM host. Dependencies include redox_installer, redoxfs, redox_syscall, tempfile, proc-mounts, toml, and redox-pkg (pkgutils lib).

#### Scenario: Successful redoxer build
- **WHEN** `nix build .#redoxer` is run
- **THEN** the output contains `bin/redoxer` as a native Linux binary

### Requirement: redoxer flake input added
A new flake input `redoxer-src` SHALL point to `gitlab:redox-os/redoxer/master?host=gitlab.redox-os.org`.

#### Scenario: Flake input resolves
- **WHEN** `nix flake lock` runs
- **THEN** the `redoxer-src` input resolves to a valid GitLab repository

### Requirement: redoxer exposed in flake
The redoxer package SHALL be exposed as `packages.${system}.redoxer` in the flake output.

#### Scenario: Flake package accessible
- **WHEN** `nix build .#redoxer` completes
- **THEN** the derivation succeeds and the output store path contains `bin/redoxer`
