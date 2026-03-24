# Tasks

## Phase 1: Expose upstream fetchurl

- [ ] 1.1 In `snix-redox/upstream/glue/src/lib.rs`, change `mod fetchurl;` to `pub mod fetchurl;`
- [ ] 1.2 In `snix-redox/upstream/glue/src/fetchurl.rs`, change `pub(crate) fn fetchurl_derivation_to_fetch` to `pub fn` and `pub(crate) enum Error` to `pub enum Error`

## Phase 2: Rewrite fetchers.rs to use upstream Fetch

- [ ] 2.1 Rewrite `fetch_to_store()` — call `fetchurl_derivation_to_fetch(drv)`, extract `out` from drv environment, match on `Fetch` variants to dispatch download (URL→flat, Tarball→unpack, NAR→extract, Executable→flat+chmod)
- [ ] 2.2 Replace `verify_fetch_hash()` — verify from the Fetch variant's expected hash directly after download instead of re-parsing the derivation's CA hash
- [ ] 2.3 Keep existing download functions (`fetch_flat`, `fetch_and_unpack`, `extract_tar`) — they handle the sync ureq download and decompression
- [ ] 2.4 Delete the old manual `url`/`out`/`unpack` extraction code and the standalone `verify_fetch_hash` function

## Phase 3: Verify

- [ ] 3.1 `nix build .#checks.x86_64-linux.snix-build` and `snix-clippy` — compilation and clippy clean
- [ ] 3.2 `nix build .#checks.x86_64-linux.snix-test` — unit tests pass (fetcher eval integration tests)
- [ ] 3.3 `nix build .#checks.x86_64-linux.functional-test` — VM test passes end-to-end (exercises builtin:fetchurl via nixpkgs fetchurl)
