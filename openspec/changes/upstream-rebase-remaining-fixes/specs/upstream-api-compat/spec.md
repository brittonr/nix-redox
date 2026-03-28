## ADDED Requirements

### Requirement: virtio-fsd compiles against redox-scheme 0.11
The custom virtio-fsd driver source must use the redox-scheme 0.11 API surface. No references to removed types (SchemeState) or old method signatures.

#### Scenario: virtio-fsd builds in base per-crate
- **WHEN** `nix build .#packages.x86_64-linux.basePerCrate` runs
- **THEN** the virtio-fsd crate compiles without errors
- **AND** the binary is present in the output

#### Scenario: virtio-fsd handles scheme events correctly
- **WHEN** the virtio-fsd binary runs on a Redox VM with virtio-fs device
- **THEN** it registers its scheme and processes FUSE requests
- **AND** file read/write operations through the virtio-fs mount work

### Requirement: redox-rt per-crate build succeeds
The redox-rt crate from relibc must compile as a per-crate build via buildRustCrate within the base workspace build plan.

#### Scenario: redox-rt resolves from relibc source
- **WHEN** the base build plan includes redox-rt as a dependency
- **THEN** buildRustCrate locates the source via the relibc-src input
- **AND** the crate compiles with the correct feature flags

### Requirement: tier-cross passes
All components in the tier-cross check must build successfully.

#### Scenario: Full tier-cross
- **WHEN** `nix build .#checks.x86_64-linux.tier-cross` runs
- **THEN** the check succeeds with exit code 0
