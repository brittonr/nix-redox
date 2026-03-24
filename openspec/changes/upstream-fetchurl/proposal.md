## Why

Our `fetchers.rs` manually parses `builtin:fetchurl` derivations — extracting `url`, `out`, `unpack` from the environment, detecting compression formats from URL suffixes, and verifying CA hashes against `CAHash::Flat` and `CAHash::Nar`. Upstream snix-glue has `fetchurl_derivation_to_fetch()` that converts derivations into a typed `Fetch` enum covering URL, Tarball, NAR, and Executable modes with proper hash expectations. Our manual parsing duplicates this and misses the Executable and NAR-from-URL modes.

Using upstream's `Fetch` type as the intermediate representation between derivation parsing and download execution keeps our sync ureq download (no async) while getting correct derivation→fetch classification for free.

## What Changes

- Expose `snix_glue::fetchurl::fetchurl_derivation_to_fetch()` as `pub` (currently `pub(crate)`)
- Rewrite `fetchers::fetch_to_store()` to call `fetchurl_derivation_to_fetch()` → match on `Fetch` variants → execute sync download
- Replace our manual `verify_fetch_hash()` with hash checking driven by the `Fetch` variant's expected hash
- Delete the manual `url`/`out`/`unpack` environment extraction and compression-format guessing
- Keep all sync download code (ureq, flate2, lzma-rs, bzip2-rs, ruzstd, tar)

## Capabilities

### New Capabilities
- `upstream-fetchurl`: Use upstream snix-glue Fetch types for builtin:fetchurl derivation parsing

### Modified Capabilities

## Impact

- `snix-redox/upstream/glue/src/lib.rs` — make `fetchurl` module public
- `snix-redox/upstream/glue/src/fetchurl.rs` — make function and error type public
- `snix-redox/src/fetchers.rs` — rewrite to use upstream Fetch types
- `snix-redox/src/local_build.rs` — minor: fetch_to_store call signature unchanged
