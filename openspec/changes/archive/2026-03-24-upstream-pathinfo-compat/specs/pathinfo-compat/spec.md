## ADDED Requirements

### Requirement: Convert local PathInfo to upstream PathInfo
The system SHALL provide `impl From<&PathInfo> for snix_store::path_info::PathInfo` that converts our local type to upstream's type. The `node` field SHALL use a dummy placeholder. The `nar_sha256` field SHALL be parsed from the `"sha256:{hex}"` string format. References, deriver, and signatures SHALL be converted to their typed upstream equivalents.

#### Scenario: Round-trip store_path
- **WHEN** a local PathInfo with `store_path = "/nix/store/abc...-hello-1.0"` is converted to upstream
- **THEN** the upstream PathInfo's `store_path` is the equivalent `StorePath<String>`

#### Scenario: Round-trip nar_hash
- **WHEN** a local PathInfo with `nar_hash = "sha256:abcdef..."` (64 hex chars) is converted
- **THEN** the upstream PathInfo's `nar_sha256` contains the decoded 32-byte array

#### Scenario: Signatures converted
- **WHEN** a local PathInfo has signatures `["cache.nixos.org-1:base64..."]`
- **THEN** the upstream PathInfo's `signatures` contains parsed `Signature<String>` values

### Requirement: Convert upstream PathInfo to local PathInfo
The system SHALL provide `impl TryFrom<&snix_store::path_info::PathInfo> for PathInfo` that converts upstream's type to our local type. The `registration_time` SHALL be set to the current timestamp. The `files` field SHALL be empty.

#### Scenario: Upstream to local store_path
- **WHEN** an upstream PathInfo is converted to local
- **THEN** the local `store_path` is the absolute path string

#### Scenario: Upstream to local nar_hash
- **WHEN** an upstream PathInfo with `nar_sha256` bytes is converted
- **THEN** the local `nar_hash` is `"sha256:{hex}"` format

### Requirement: Construct PathInfo from NarInfo
The system SHALL provide `PathInfo::from_narinfo()` that constructs a local PathInfo from an upstream `NarInfo` and a store path string. This SHALL replace manual narinfo field extraction in cache code.

#### Scenario: NarInfo to PathInfo fields
- **WHEN** a NarInfo with nar_hash, nar_size, references, and signatures is converted
- **THEN** the resulting PathInfo has all fields populated correctly

#### Scenario: Used in cache fetch
- **WHEN** `cache.rs` fetches a narinfo from a binary cache
- **THEN** it uses `PathInfo::from_narinfo()` instead of manually extracting fields

### Requirement: Convert local PathInfo to NarInfo
The system SHALL provide `PathInfo::to_narinfo()` that produces an upstream `NarInfo` for rendering .narinfo files or verifying signatures.

#### Scenario: NarInfo has correct hash
- **WHEN** a local PathInfo is converted to NarInfo
- **THEN** the NarInfo's `nar_hash` matches the local PathInfo's decoded hash bytes
