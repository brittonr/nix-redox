## Context

snix-redox currently reimplements three pieces of functionality that upstream snix provides:

1. **Reference scanning** — `scan_references()` in `local_build.rs` iterates each candidate hash and calls `windows().any()` on file content. O(candidates × file_size). Upstream `snix-castore::refscan` uses Wu-Manber multi-pattern matching: O(file_size) regardless of candidate count, and handles matches spanning read boundaries.

2. **Tar extraction** — `fetchers.rs` has a hand-rolled tar parser (~200 lines) that parses headers byte-by-byte. Missing: pax extended headers, long GNU filenames, proper octal parsing edge cases. The `tar` crate handles all of these.

3. **Builder env vars** — `local_build.rs` manually sets `HOME`, `TMPDIR`, `NIX_BUILD_TOP`, etc. Upstream `snix-glue::builder` defines these as `NIX_ENVIRONMENT_VARS`.

## Goals / Non-Goals

**Goals:**
- Replace custom reference scanning with upstream `ReferenceScanner`
- Replace hand-rolled tar parser with `tar` crate
- Use upstream env var constant
- All existing tests pass unchanged
- No new async dependencies in the sync code paths

**Non-Goals:**
- Replacing the sync binary cache client (ureq) with upstream async fetchers
- Replacing the JSON-file PathInfo store with upstream PathInfoService
- Replacing the NAR hashing code (already uses nix-compat correctly)
- Adding the full upstream BuildRequest pipeline

## Decisions

### Use `snix-castore::refscan::ReferenceScanner` directly (not `ReferenceReader`)

The upstream scanner has two components: `ReferenceScanner` (sync `.scan(&[u8])` method) and `ReferenceReader` (async wrapper). We only need the sync scanner — post-build reference scanning reads files from disk synchronously.

The `ReferencePattern` is constructed from nixbase32 hashes (32 bytes each), matching exactly what our `collect_potential_references` produces. After scanning, `candidate_matches()` yields matched patterns.

Alternative: keep custom code. Rejected because Wu-Manber is strictly faster and handles boundary-crossing matches that the naive `windows()` approach misses if we ever scan in chunks.

### Use `tar` crate (sync) instead of `tokio-tar`

`tokio-tar` is in workspace dependencies but requires async. The fetcher code path (`fetch_and_unpack`) is sync (uses ureq). Adding a tokio runtime just for tar extraction is unnecessary overhead.

The `tar` crate is pure Rust, sync, battle-tested, and handles all POSIX tar features. It replaces `extract_tar`, `parse_tar_string`, `parse_tar_octal`, `skip_tar_data` — roughly 200 lines.

Top-level directory stripping (matching current behavior): use `tar::Archive::entries()` and strip the first path component.

### Import `NIX_ENVIRONMENT_VARS` from upstream glue

The constant is a `[(&str, &str); 12]` array. Import it directly. Our `build_derivation_inner` still overrides with derivation-specific env vars after applying these defaults, matching current behavior.

## Risks / Trade-offs

- [Wu-Manber dependency] The `wu-manber` crate is a git dependency from tvlfyi. It's already transitively pulled in via `snix-castore`. → No new dependency, just using what's already compiled.
- [tar crate addition] New direct dependency. → Well-maintained (100M+ downloads), no unsafe, no system deps. Already common in the Rust ecosystem.
- [Top-level stripping behavior change] The hand-rolled tar parser strips the first path component. The `tar` crate doesn't by default. → Implement stripping manually by iterating entries and adjusting paths, matching current behavior exactly.
- [Feature flags on snix-castore] `refscan` module availability may depend on feature flags. → Check if it's behind a feature gate; if so, enable it in Cargo.toml.
