## ADDED Requirements

### Requirement: redox_intelflash builds for Redox target
The build system SHALL cross-compile redox_intelflash from `intelflash-src` flake input for `x86_64-unknown-redox`. Dependencies: bitflags 2.5, plain 0.2, redox_uefi 0.1.

#### Scenario: Successful intelflash build
- **WHEN** `nix build .#redox-intelflash` is run
- **THEN** the output contains the compiled intelflash library for x86_64-unknown-redox

### Requirement: intelflash flake input added
A new flake input `intelflash-src` SHALL point to `gitlab:redox-os/intelflash/master?host=gitlab.redox-os.org`.

#### Scenario: Flake input resolves
- **WHEN** `nix flake lock` runs
- **THEN** the `intelflash-src` input resolves to a valid GitLab repository
