## ADDED Requirements

### Requirement: Parse builtin:fetchurl derivations via upstream Fetch type
The system SHALL use `snix_glue::fetchurl::fetchurl_derivation_to_fetch()` to convert `builtin:fetchurl` derivations into typed `Fetch` variants. The `Fetch` enum classification SHALL determine the download mode (flat file, tarball unpack, NAR extraction, executable).

#### Scenario: Flat URL fetch
- **WHEN** a derivation has `builder = "builtin:fetchurl"` with `CAHash::Flat`
- **THEN** `fetchurl_derivation_to_fetch()` returns `Fetch::URL` with the URL and expected hash

#### Scenario: Tarball unpack fetch
- **WHEN** a derivation has `builder = "builtin:fetchurl"` with `CAHash::Nar` and `unpack=1`
- **THEN** `fetchurl_derivation_to_fetch()` returns `Fetch::Tarball` with the URL and expected NAR hash

#### Scenario: Executable fetch
- **WHEN** a derivation has `builder = "builtin:fetchurl"` with `CAHash::Nar` and `executable=1`
- **THEN** `fetchurl_derivation_to_fetch()` returns `Fetch::Executable` with the URL and hash

### Requirement: Sync download execution driven by Fetch variants
The system SHALL execute downloads using sync ureq HTTP, dispatching on the `Fetch` variant. `Fetch::URL` downloads to a flat file. `Fetch::Tarball` downloads and unpacks. `Fetch::NAR` downloads and extracts NAR. `Fetch::Executable` downloads and sets executable permission.

#### Scenario: Sync flat download
- **WHEN** `Fetch::URL { url, exp_hash }` is processed
- **THEN** the URL is downloaded via ureq and written to the output path

#### Scenario: Sync tarball download with unpack
- **WHEN** `Fetch::Tarball { url, exp_nar_sha256 }` is processed
- **THEN** the URL is downloaded, decompressed, and extracted to the output directory

### Requirement: Hash verification from Fetch expected hash
The system SHALL verify output hashes using the expected hash carried in the `Fetch` variant, not by re-parsing the derivation's CA hash.

#### Scenario: Flat hash verification
- **WHEN** `Fetch::URL` carries `exp_hash = Some(NixHash::Sha256(bytes))`
- **THEN** the downloaded file's SHA-256 is compared against the expected bytes

#### Scenario: NAR hash verification
- **WHEN** `Fetch::Tarball` carries `exp_nar_sha256 = Some(bytes)`
- **THEN** the extracted output's NAR hash is compared against the expected bytes
