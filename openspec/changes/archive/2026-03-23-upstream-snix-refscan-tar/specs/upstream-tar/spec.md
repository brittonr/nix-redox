## ADDED Requirements

### Requirement: Tar extraction uses the tar crate
The `fetch_and_unpack` function SHALL use the `tar` crate for extracting tar archives instead of hand-rolled parsing. The extracted archive SHALL have its top-level directory component stripped.

#### Scenario: Standard tarball with top-level directory
- **WHEN** a tarball contains entries like `project-v1.0/src/main.rs`
- **THEN** extraction produces `src/main.rs` under the output path (first component stripped)

#### Scenario: Tarball with symlinks
- **WHEN** a tarball contains symbolic links
- **THEN** the symlinks are preserved in the extracted output

#### Scenario: Tarball with executable files
- **WHEN** a tarball contains files with executable permission bits
- **THEN** the extracted files retain their executable permissions

#### Scenario: Compressed tarball formats
- **WHEN** a tarball is compressed with gzip, xz, bzip2, or zstd
- **THEN** the decompression step produces a valid tar stream for the tar crate

#### Scenario: Empty tarball
- **WHEN** a tarball contains no entries
- **THEN** extraction creates the output directory without error

### Requirement: Hand-rolled tar functions removed
The functions `extract_tar`, `parse_tar_string`, `parse_tar_octal`, and `skip_tar_data` SHALL be removed from `fetchers.rs`.

#### Scenario: No custom tar parsing code remains
- **WHEN** the change is complete
- **THEN** `fetchers.rs` contains no manual tar header parsing
