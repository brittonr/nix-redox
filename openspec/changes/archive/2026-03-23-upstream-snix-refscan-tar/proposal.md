## Why

snix-redox reimplements functionality that upstream snix already provides. The reference scanner uses naive O(candidates × filesize) sliding window matching instead of upstream's Wu-Manber multi-pattern algorithm. The tar extractor is 200+ lines of hand-rolled parsing that misses pax headers, long filenames, and other POSIX tar edge cases. Replacing these with upstream code reduces maintenance burden and improves correctness.

## What Changes

- Replace the custom `scan_references` / `collect_potential_references` in `local_build.rs` with upstream `snix-castore::refscan::ReferenceScanner` (Wu-Manber algorithm, sync-compatible)
- Replace hand-rolled tar parser in `fetchers.rs` (`extract_tar`, `parse_tar_string`, `parse_tar_octal`, `skip_tar_data`) with the `tar` crate
- Use upstream `snix-glue::builder::NIX_ENVIRONMENT_VARS` constant instead of manually duplicating env var setup in `local_build.rs`

## Capabilities

### New Capabilities
- `upstream-refscan`: Replace custom reference scanning with upstream snix-castore Wu-Manber scanner
- `upstream-tar`: Replace hand-rolled tar extraction with the `tar` crate
- `upstream-env-vars`: Use upstream builder environment variable constants

### Modified Capabilities

## Impact

- `snix-redox/src/local_build.rs`: reference scanning functions replaced, env setup simplified
- `snix-redox/src/fetchers.rs`: tar extraction functions replaced, ~200 lines removed
- `snix-redox/Cargo.toml`: add `tar` crate dependency, enable `refscan` feature on snix-castore if needed
- All existing tests must continue passing — the behavior is identical, just using upstream implementations
