## ADDED Requirements

### Requirement: redox-buffer-pool builds for Redox target
The build system SHALL cross-compile redox-buffer-pool from `buffer-pool-src` flake input for `x86_64-unknown-redox` with the `redox` feature enabled (activates redox_syscall dependency for scheme-based shared memory). Dependencies: guard-trait, log, redox_syscall (with redox feature).

#### Scenario: Successful buffer-pool build
- **WHEN** `nix build .#redox-buffer-pool` is run
- **THEN** the output contains the compiled buffer-pool library for x86_64-unknown-redox

### Requirement: buffer-pool flake input added
A new flake input `buffer-pool-src` SHALL point to `gitlab:redox-os/redox-buffer-pool/master?host=gitlab.redox-os.org`.

#### Scenario: Flake input resolves
- **WHEN** `nix flake lock` runs
- **THEN** the `buffer-pool-src` input resolves to a valid GitLab repository
