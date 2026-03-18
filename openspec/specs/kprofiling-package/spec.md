## ADDED Requirements

### Requirement: redox-kprofiling builds as host tool
The build system SHALL build redox-kprofiling natively for the host (Linux) from `kprofiling-src` flake input. This is a converter that reads kernel profiling data and outputs perf script format. Only dependency is anyhow.

#### Scenario: Successful kprofiling build
- **WHEN** `nix build .#redox-kprofiling` is run
- **THEN** the output contains a native Linux binary that can convert Redox kernel profiling data

### Requirement: kprofiling flake input added
A new flake input `kprofiling-src` SHALL point to `gitlab:redox-os/kprofiling/master?host=gitlab.redox-os.org`.

#### Scenario: Flake input resolves
- **WHEN** `nix flake lock` runs
- **THEN** the `kprofiling-src` input resolves to a valid GitLab repository
