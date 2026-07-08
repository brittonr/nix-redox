## ADDED Requirements

### Requirement: Redox substrate reproducible VM build [r[system-builder.redox-substrate-reproducible-vm-build]]

Redox SHALL provide a checked-in substrate VM build path that materializes required VM proof artifacts from the public substrate builder shell without proof-only temporary package files or operator-specific fetch environment.

#### Scenario: VM proof artifacts build from public surface [r[system-builder.redox-substrate-reproducible-vm-build.scenario.artifacts]]

- GIVEN a valid primitive plan consumes `legacyPackages.${system}.redoxSubstrate`
- WHEN the reproducible VM proof build runs
- THEN it MUST produce kernel, initfs, RedoxFS image, disk image, and QEMU runner outputs
- AND it MUST NOT require callers to import private Redox package files or patch package definitions outside the repository

#### Scenario: Fixed-output fetch inputs are deterministic [r[system-builder.redox-substrate-reproducible-vm-build.scenario.fixed-output]]

- GIVEN substrate infrastructure packages use fixed-output source or vendor fetches
- WHEN the build runs in a clean environment
- THEN the hashes and certificate inputs MUST be declared by the derivation or checked-in check
- AND missing certificate configuration MUST fail with a diagnostic naming the missing input rather than relying on an operator shell override

#### Scenario: Heavy QEMU execution is explicit [r[system-builder.redox-substrate-reproducible-vm-build.scenario.manual-qemu]]

- GIVEN real QEMU execution is too heavy for default CI
- WHEN Redox exposes the proof runner
- THEN the command MAY be manual or opt-in
- AND it MUST still build from checked-in sources and record the artifact paths and guest receipt expectations needed by an external OnixOS harness
