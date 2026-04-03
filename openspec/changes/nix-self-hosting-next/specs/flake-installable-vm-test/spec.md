## ADDED Requirements

### Requirement: Flake installable builds produce store output in VM
The system SHALL support `snix build .#<attr>` end-to-end on a running Redox guest. Given a flake directory with `flake.nix`, `flake.lock`, and pre-fetched input sources, snix SHALL parse the installable, resolve locked inputs from local paths, evaluate the flake outputs expression, build the resulting derivation, and produce an output in `/nix/store/`.

#### Scenario: Build a Rust hello-world from a test flake
- **WHEN** the guest has `/usr/src/test-flake/` containing a valid `flake.nix`, `flake.lock`, and pre-fetched input source
- **AND** the user runs `snix build /usr/src/test-flake#hello`
- **THEN** snix produces an output path in `/nix/store/` containing `bin/hello`
- **AND** executing the binary prints `Hello from flake!`

#### Scenario: Flake output is registered in PathInfoDb
- **WHEN** `snix build /usr/src/test-flake#hello` succeeds
- **THEN** `snix store info <output-path>` returns metadata including a SHA-256 hash

#### Scenario: Cached flake build skips rebuild
- **WHEN** `snix build /usr/src/test-flake#hello` is run a second time
- **THEN** snix returns the same output path without re-executing the builder

### Requirement: Test flake source bundle ships on disk image
The build system SHALL produce a `test-flake-bundle` derivation containing a minimal flake with: a `flake.nix` that defines one Rust package, a `flake.lock` referencing local inputs, vendored Cargo dependencies, and a `build.nix` builder script. The self-hosting test profile SHALL include this bundle at `/usr/src/test-flake/`.

#### Scenario: Test flake bundle present on self-hosting image
- **WHEN** the self-hosting-test VM boots
- **THEN** `/usr/src/test-flake/flake.nix` exists
- **AND** `/usr/src/test-flake/flake.lock` exists
- **AND** `/usr/src/test-flake/src/` contains Rust source files

### Requirement: VM test emits FUNC_TEST protocol verdicts
The flake installable VM test SHALL emit `FUNC_TEST:flake-build:PASS` or `FUNC_TEST:flake-build:FAIL:<reason>` for the test harness to collect. It SHALL be part of the self-hosting-test profile.

#### Scenario: Test result captured by harness
- **WHEN** the self-hosting-test VM runs the flake installable test
- **THEN** serial output contains exactly one `FUNC_TEST:flake-build:PASS` or `FUNC_TEST:flake-build:FAIL:` line
