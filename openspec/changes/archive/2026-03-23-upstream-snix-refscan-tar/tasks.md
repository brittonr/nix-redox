## 1. Reference Scanning

- [x] 1.1 Add `snix-castore` refscan dependency: enable the module in snix-redox's Cargo.toml (add `wu-manber` to workspace deps if needed, ensure `refscan` is accessible)
- [x] 1.2 Replace `scan_references` and `scan_path` in `local_build.rs` with upstream `ReferenceScanner` — build `ReferencePattern` from nixbase32 hashes, scan files/dirs/symlinks, return `BTreeSet<String>` of matched store paths
- [x] 1.3 Update existing reference scanning tests to verify behavior is identical

## 2. Tar Extraction

- [x] 2.1 Add `tar` crate dependency to snix-redox Cargo.toml
- [x] 2.2 Replace `extract_tar` in `fetchers.rs` with `tar` crate — iterate entries, strip top-level directory component, extract files/dirs/symlinks with correct permissions
- [x] 2.3 Remove hand-rolled tar functions: `parse_tar_string`, `parse_tar_octal`, `skip_tar_data`, and the old `extract_tar`
- [x] 2.4 Update existing tar extraction tests

## 3. Builder Environment Variables

- [x] 3.1 Import `NIX_ENVIRONMENT_VARS` from `snix_glue::builder` in `local_build.rs` and use it to populate the default build environment, removing the manual env var setup
- [x] 3.2 Verify derivation env vars still override defaults

## 4. Validation

- [x] 4.1 Run `cargo test` for snix-redox and confirm all tests pass
- [x] 4.2 Run `cargo check --target x86_64-unknown-redox` to confirm cross-compilation
