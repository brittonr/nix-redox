## ADDED Requirements

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
