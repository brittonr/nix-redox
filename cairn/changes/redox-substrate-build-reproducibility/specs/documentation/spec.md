## ADDED Requirements

### Requirement: Redox substrate reproducible proof documentation [r[documentation.redox-substrate-reproducible-proof]]

Redox documentation SHALL describe the reproducible substrate VM proof path, including how to build artifacts, when to run real QEMU, how to interpret evidence, and which support claims remain out of scope.

#### Scenario: Operator can rerun the proof [r[documentation.redox-substrate-reproducible-proof.scenario.rerun]]

- GIVEN an operator wants to reproduce the OnixOS Redox VM artifact build
- WHEN they read the Redox substrate documentation
- THEN they MUST find the checked-in command or flake output to build the proof artifacts
- AND they MUST find expected output names for kernel, initfs, RedoxFS image, disk image, and QEMU runner

#### Scenario: Non-claims stay explicit [r[documentation.redox-substrate-reproducible-proof.scenario.boundary]]

- GIVEN the reproducible VM proof succeeds
- WHEN documentation describes the result
- THEN it MUST state that the check proves Redox artifact materialization and optional VM boot only
- AND it MUST NOT claim OnixOS deploy, activation, physical install, rollback, power-loss, or broad service/provider support
