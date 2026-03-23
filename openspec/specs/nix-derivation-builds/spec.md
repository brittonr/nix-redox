## MODIFIED Requirements

### Requirement: snix-compile goes through snix build
The snix self-compile test SHALL invoke `snix build --file /usr/src/snix-redox/build.nix` instead of running `cargo build --offline` directly. The builder script (`build-snix.sh`) SHALL be pre-installed in the snix source bundle. The compiled snix binary SHALL be produced in a `/nix/store/` output path. The build execution SHALL use upstream `derivation_into_build_request()` for environment setup, with temp dir paths substituted to the actual build directory.

#### Scenario: snix self-compile via snix build
- **WHEN** the self-hosting test reaches the snix-compile phase
- **THEN** it runs `snix build --file /usr/src/snix-redox/build.nix` and the output path contains a working `snix` binary at `$out/bin/snix`

#### Scenario: snix-compile PASS verdict
- **WHEN** `snix build` succeeds and the output binary runs `--version` without error
- **THEN** the test emits `FUNC_TEST:snix-compile:PASS`

#### Scenario: snix-compile FAIL on build failure
- **WHEN** `snix build` exits non-zero or the output binary is missing
- **THEN** the test emits `FUNC_TEST:snix-compile:FAIL:<reason>` with build log context
