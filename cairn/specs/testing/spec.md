# Testing Specification

## Purpose

Defines the `testing` capability.

## Requirements

### Requirement: Redox substrate compatibility [r[testing.redox-substrate-compatibility]]

Redox MUST include focused tests or checks that exercise the public substrate ingredient surface from the perspective of an external OnixOS/Mantle consumer. Coverage MUST include successful primitive-plan materialization and negative fail-closed cases for malformed or unsupported inputs.

#### Scenario: Substrate fixture builds from public surface [r[testing.redox-substrate-compatibility.scenario.public-surface]]

- GIVEN a fixture consumes only the public Redox substrate manifest, primitive schemas, and builder shell
- AND the fixture declares one service, one filesystem entry, and one networking setting
- WHEN the fixture evaluates or builds the relevant artifact
- THEN the resulting artifact plan or build output MUST include every primitive contribution
- AND the fixture MUST NOT import private Redox internals or construct Adios path-keyed modules

#### Scenario: Private-internal import regression caught [r[testing.redox-substrate-compatibility.scenario.private-import]]

- GIVEN the substrate fixture is checked
- WHEN dependency/import validation runs
- THEN the check MUST fail if the fixture imports private files under `nix/flake-modules` or package implementation directories instead of the public substrate surface

#### Scenario: Negative substrate inputs fail clearly [r[testing.redox-substrate-compatibility.scenario.negative]]

- GIVEN fixtures with malformed service argv, unsupported networking fields, missing substrate ingredients, or conflicting filesystem entries
- WHEN compatibility checks run
- THEN each fixture MUST fail with a diagnostic naming the invalid substrate primitive
- AND no fixture may pass by silently dropping malformed data

### Requirement: Redox substrate reproducibility coverage [r[testing.redox-substrate-reproducibility-coverage]]

Redox SHALL include positive and negative coverage for the reproducible substrate VM proof path before downstream consumers treat it as a stable input.

#### Scenario: Positive reproducibility check covers artifact families [r[testing.redox-substrate-reproducibility-coverage.scenario.positive]]

- GIVEN the checked-in substrate VM proof fixture is evaluated or built
- WHEN focused substrate checks run
- THEN they MUST prove the public surface can produce or plan kernel, initfs, RedoxFS, disk image, and QEMU runner outputs
- AND the fixture MUST NOT import private package implementation files

#### Scenario: Negative reproducibility checks fail closed [r[testing.redox-substrate-reproducibility-coverage.scenario.negative]]

- GIVEN fixtures or checks with stale fixed-output hashes, missing certificate inputs, private package imports, malformed service argv, missing ingredients, or unsupported primitive requests
- WHEN substrate compatibility checks run
- THEN each case MUST fail with a deterministic diagnostic naming the invalid input
- AND no check MAY pass by silently substituting a different package, profile, or runtime
