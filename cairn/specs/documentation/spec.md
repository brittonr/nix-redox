# Documentation Specification

## Purpose

Defines the `documentation` capability.

## Requirements

### Requirement: Redox substrate contract documentation [r[documentation.redox-substrate-contract]]

Redox documentation MUST describe the public substrate ingredient surface, native primitive schemas, builder shell, and boundary between Redox-owned substrate mechanics and OnixOS-owned system semantics.

The documentation MUST state that Redox does not depend on OnixOS, onix-modules, Nickel, or Mantle, and that Redox Adios modules remain an internal/native development workflow rather than the required external OnixOS system contract.

#### Scenario: OnixOS substrate author finds supported surface [r[documentation.redox-substrate-contract.scenario.surface]]

- GIVEN an OnixOS substrate author wants to target Redox
- WHEN they read the documentation
- THEN they MUST find the public substrate manifest fields, primitive plan shape, and builder shell entrypoints
- AND they MUST find a minimal primitive-plan example

#### Scenario: Runtime caveats are explicit [r[documentation.redox-substrate-contract.scenario.caveats]]

- GIVEN a frontend author assumes POSIX shell, NixOS options, or guest-side Onix evaluation
- WHEN they read the documentation
- THEN they MUST find explicit caveats explaining Redox/Ion/runtime differences and out-of-scope behavior

#### Scenario: Evidence distinction is explicit [r[documentation.redox-substrate-contract.scenario.evidence]]

- GIVEN a build uses Nix-backed Redox substrate builders during development
- WHEN an operator reads the documentation
- THEN they MUST see that Nix-bootstrap evidence is distinct from Mantle/no-Nix-runtime supported evidence

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
