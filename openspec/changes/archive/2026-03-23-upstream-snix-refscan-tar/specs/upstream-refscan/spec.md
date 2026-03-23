## ADDED Requirements

### Requirement: Reference scanning uses upstream Wu-Manber scanner
The build system SHALL use `snix_castore::refscan::ReferenceScanner` for scanning build outputs for store path references. The scanner SHALL be constructed from nixbase32 hash candidates and SHALL scan file contents, directory trees, and symlink targets.

#### Scenario: Single file contains a store path reference
- **WHEN** a build output file contains a nixbase32 hash of a candidate store path
- **THEN** the scanner reports that store path as a reference

#### Scenario: No store path references found
- **WHEN** a build output contains no candidate nixbase32 hashes
- **THEN** the scanner returns an empty reference set

#### Scenario: Multiple references in directory tree
- **WHEN** a build output directory tree contains nixbase32 hashes in files across subdirectories
- **THEN** the scanner reports all matching store paths as references

#### Scenario: Self-reference detected
- **WHEN** a build output contains its own nixbase32 hash
- **THEN** the scanner includes the output path in the reference set

#### Scenario: Symlink target contains reference
- **WHEN** a symlink target string contains a nixbase32 hash of a candidate
- **THEN** the scanner reports that store path as a reference

### Requirement: Candidate collection unchanged
The system SHALL collect potential reference candidates from the same sources as before: input sources, resolved outputs of input derivations, and the output path itself.

#### Scenario: Candidates from input derivations
- **WHEN** a derivation has input derivations with resolved output paths
- **THEN** all resolved output nixbase32 hashes are included as candidates
