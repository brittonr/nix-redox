## ADDED Requirements

### Requirement: snix discovers CA bundles through one deterministic path

snix SHALL use a single CA bundle discovery helper for all TLS-dependent operations. The helper SHALL either return a concrete CA bundle path from a deterministic search order or report that no CA bundle is available.

#### Scenario: CA bundle found in supported guest path
- **WHEN** snix starts on a guest image that contains a supported CA bundle path
- **THEN** the helper returns that path
- **AND** TLS-dependent commands use it for trust-root initialization

#### Scenario: CA bundle missing
- **WHEN** snix starts on a guest image with no supported CA bundle path
- **THEN** the helper reports an explicit missing-CA state
- **AND** snix does not panic while determining trust roots

### Requirement: TLS-dependent commands fail clearly without trust roots

Commands that require HTTPS SHALL return a clear error when no CA bundle is available. Local-only commands that do not require HTTPS SHALL continue to work.

#### Scenario: Remote fetch without CA bundle
- **WHEN** a user runs a TLS-dependent remote fetch or channel command on a guest with no CA bundle
- **THEN** snix exits with a clear error explaining that no CA bundle is available
- **AND** the error names the checked path(s) or configured source of trust roots

#### Scenario: Local eval/build without CA bundle
- **WHEN** a user runs a local-only eval or build command on the same guest
- **THEN** the command still works
- **AND** it does not fail merely because TLS trust roots are unavailable

### Requirement: Packaged and self-built snix share the same trust behavior

The installed snix binary and the self-built/source-bundle snix binary SHALL use the same CA discovery and missing-CA behavior.

#### Scenario: Packaged and self-built snix hit the same HTTPS fixture
- **WHEN** both binaries access the same HTTPS-backed remote cache or channel fixture
- **THEN** both either succeed with the same CA bundle
- **OR** fail with the same missing-CA style error
- **AND** neither path panics
