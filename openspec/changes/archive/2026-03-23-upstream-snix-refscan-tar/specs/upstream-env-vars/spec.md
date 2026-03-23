## ADDED Requirements

### Requirement: Builder environment uses upstream constants
The build environment setup SHALL import `NIX_ENVIRONMENT_VARS` from `snix_glue::builder` instead of manually defining the standard Nix build environment variables.

#### Scenario: Standard env vars match upstream
- **WHEN** a derivation is built
- **THEN** the builder process receives HOME, NIX_BUILD_TOP, TMPDIR, TEMPDIR, TMP, TEMP, NIX_STORE, and PATH with values matching upstream snix defaults

#### Scenario: Derivation env vars override defaults
- **WHEN** a derivation's environment sets PATH or other standard variables
- **THEN** the derivation values take precedence over the upstream defaults
