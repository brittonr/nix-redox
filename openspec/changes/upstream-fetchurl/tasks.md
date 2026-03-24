# Tasks

## Phase 1: Expose upstream fetchurl

- [x] 1.1 In `snix-upstream-source.nix`, add sed patches to make `fetchurl` module public in `glue/src/lib.rs`
- [x] 1.2 In `snix-upstream-source.nix`, add sed patches to make `fetchurl_derivation_to_fetch` and `Error` public in `glue/src/fetchurl.rs`

## Phase 2: Rewrite fetchers.rs to use upstream Fetch

- [x] 2.1 Rewrite `fetch_to_store()` — call `fetchurl_derivation_to_fetch(drv)`, extract `out` from drv environment, match on `Fetch` variants to dispatch download (URL→flat, Tarball→unpack, NAR→extract, Executable→flat+chmod)
- [x] 2.2 Replace `verify_fetch_hash()` — verify from the Fetch variant's expected hash directly after download instead of re-parsing the derivation's CA hash
- [x] 2.3 Keep existing download functions (`fetch_flat`, `fetch_and_unpack`, `extract_tar`) — refactored with shared `decompress_reader` helper
- [x] 2.4 Added `fetch_nar` for NAR-from-URL downloads (new capability from Fetch::NAR variant)
- [x] 2.5 Added Fetch::Executable handling (flat download + chmod 755, new capability)

## Phase 3: Verify

- [x] 3.1 `nix build .#checks.x86_64-linux.snix-build` and `snix-clippy` — compilation and clippy clean
- [x] 3.2 `nix build .#checks.x86_64-linux.snix-test` — pre-existing failure (tempfile dev-dep missing from build-plan.json), not related to this change
- [x] 3.3 `nix build .#checks.x86_64-linux.functional-test` — VM test passes end-to-end
