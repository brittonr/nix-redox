## MODIFIED Requirements

### Requirement: Flake installable builds produce store output in VM
The system SHALL support `snix build .#<attr>` end-to-end on a running Redox guest. Given a flake directory with `flake.nix`, `flake.lock`, and pre-fetched input sources, snix SHALL parse the installable, resolve locked inputs from local paths, evaluate the flake outputs expression, build the resulting derivation, and produce an output in `/nix/store/`.

This requirement is validated by the VM test suite. The flake parsing, lock resolution, evaluation, and build SHALL all work under the real Redox kernel with the per-path sandbox.

#### Scenario: Build a Rust hello-world from a test flake on guest
- **WHEN** the guest runs `snix build /usr/src/test-flake#hello`
- **THEN** the output path in `/nix/store/` contains `bin/hello`
- **AND** executing the binary prints `Hello from flake!`
- **AND** the test emits `FUNC_TEST:flake-build:PASS`

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
