## ADDED Requirements

### Requirement: Build environment uses upstream BuildRequest conversion
`build_derivation_inner()` SHALL use `snix_glue::builder::derivation_into_build_request()` to produce environment variables, command arguments, output paths, and refscan needles instead of constructing them manually from the raw Derivation struct.

#### Scenario: Environment variables match upstream
- **WHEN** a derivation is built
- **THEN** the builder process receives the same environment variables that upstream's BuildRequest produces, with temp dir paths substituted to the actual build directory

#### Scenario: Command args from BuildRequest
- **WHEN** a derivation with builder `/bin/sh` and arguments `["-e", "builder.sh"]` is built
- **THEN** the spawned process uses command_args from the BuildRequest (`["/bin/sh", "-e", "builder.sh"]`)

### Requirement: Refscan uses BuildRequest needles
Reference scanning SHALL use `BuildRequest.refscan_needles` instead of manually collecting potential reference hashes from input derivations and outputs.

#### Scenario: References detected via needles
- **WHEN** a build output contains a nixbase32 hash that appears in `refscan_needles`
- **THEN** the corresponding store path is recorded as a reference

#### Scenario: Output self-references detected
- **WHEN** a build output contains its own store path hash
- **THEN** the output path is included in its own references (same as current behavior)

### Requirement: Additional files written to build directory
`BuildRequest.additional_files` SHALL be written into the build directory before the builder is spawned. This enables passAsFile and structuredAttrs derivations.

#### Scenario: passAsFile env var written to file
- **WHEN** a derivation uses `passAsFile = ["foo"]` with `foo = "bar"`
- **THEN** the BuildRequest contains an additional file at `build/.attr-{hash}` with contents `bar`, and the builder receives `fooPath=/build/.attr-{hash}` in its environment

#### Scenario: structuredAttrs JSON file
- **WHEN** a derivation uses `__structuredAttrs = true`
- **THEN** the BuildRequest contains additional files for `.attrs.json` and `.attrs.sh`, and the builder receives `NIX_ATTRS_JSON_FILE` and `NIX_ATTRS_SH_FILE` environment variables

### Requirement: FOD detection uses BuildRequest constraints
Fixed-output derivation detection (for sandbox network access) SHALL use `BuildRequest.constraints` containing `NetworkAccess` instead of manually checking `outputHash` in the derivation environment.

#### Scenario: FOD gets network access
- **WHEN** a fixed-output derivation is built
- **THEN** `BuildRequest.constraints` contains `NetworkAccess`, and the sandbox grants network scheme access

#### Scenario: Regular derivation denied network
- **WHEN** a non-FOD derivation is built
- **THEN** `BuildRequest.constraints` does not contain `NetworkAccess`

### Requirement: Duplicate NIX_ENVIRONMENT_VARS removed
The local `NIX_ENVIRONMENT_VARS` constant in `local_build.rs` SHALL be removed. Environment variable defaults SHALL come from the upstream BuildRequest conversion.

#### Scenario: No duplicate constant
- **WHEN** `local_build.rs` is compiled
- **THEN** it does not define its own `NIX_ENVIRONMENT_VARS` array
