## ADDED Requirements

### Requirement: gdb-protocol builds for Redox target
The build system SHALL cross-compile the gdb-protocol library crate from `gdb-protocol-src` flake input for `x86_64-unknown-redox`. The only dependency is memchr (pure Rust, no platform-specific issues).

#### Scenario: Successful gdb-protocol build
- **WHEN** `nix build .#gdb-protocol` is run
- **THEN** the output contains a compiled `.rlib` or static library for x86_64-unknown-redox

### Requirement: gdb-protocol flake input added
A new flake input `gdb-protocol-src` SHALL point to `gitlab:redox-os/gdb-protocol/master?host=gitlab.redox-os.org`.

#### Scenario: Flake input resolves
- **WHEN** `nix flake lock` runs
- **THEN** the `gdb-protocol-src` input resolves to a valid GitLab repository
