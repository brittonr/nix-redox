## ADDED Requirements

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
