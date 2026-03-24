## Context

Our `fetchers.rs` handles `builtin:fetchurl` derivation execution during local builds. When `local_build.rs` encounters a derivation with `builder = "builtin:fetchurl"`, it calls `fetchers::fetch_to_store(drv)` which manually extracts `url`, `out`, and `unpack` from the derivation environment, downloads with ureq, and verifies the hash.

Upstream snix-glue separates this into two phases: `fetchurl_derivation_to_fetch()` converts a `Derivation` into a typed `Fetch` enum, and `Fetcher::do_fetch()` executes the download async. We want the first phase but not the second — our builds run sync on Redox without a tokio runtime in the build path.

## Goals / Non-Goals

**Goals:**
- Use upstream `Fetch` enum as the typed representation of what to download
- Use upstream derivation→Fetch parsing to classify fetch mode (flat URL, NAR, tarball, executable)
- Keep sync ureq-based downloads — no tokio in the build execution path
- Simplify hash verification using the `Fetch` variant's expected hash field

**Non-Goals:**
- Using upstream's async `Fetcher::do_fetch()` execution
- Changing the download library (ureq stays)
- Altering the NAR extraction or tar extraction code

## Decisions

### Expose upstream fetchurl as public

`fetchurl_derivation_to_fetch()` is `pub(crate)` in snix-glue. Since snix-glue is a local workspace member, we change `mod fetchurl;` → `pub mod fetchurl;` in `lib.rs` and make the function and error type `pub`. Minimal patch to upstream code.

### Match on Fetch variants for download dispatch

Replace the current `unpack` boolean check with a `match` on `Fetch` variants:
- `Fetch::URL { url, exp_hash }` — flat download, verify content hash
- `Fetch::Tarball { url, exp_nar_sha256 }` — download + unpack tarball, verify NAR hash
- `Fetch::NAR { url, hash }` — download NAR, extract, verify NAR hash
- `Fetch::Executable { url, hash }` — download flat, set executable, verify hash

### Keep output path from derivation environment

Upstream's `Fetch` doesn't carry the output path — it comes from the derivation's `out` environment variable. We still extract `out` from `drv.environment`, but the URL and hash come from the `Fetch`.

### Hash verification from Fetch expected hash

Each `Fetch` variant carries its expected hash. Instead of separately calling `verify_fetch_hash()` which re-parses the derivation's CA hash, we verify directly from the `Fetch` variant's `exp_hash`/`exp_nar_sha256`/`hash` field.

## Risks / Trade-offs

**[Upstream visibility patch]** Making `fetchurl` module public is a divergence from upstream. Minimal — just visibility change, no logic changes. If upstream makes it public later, we remove our patch.

**[Fetch::Executable not previously handled]** Our code didn't handle the `executable` environment variable. Using upstream's `Fetch` adds this for free via `Fetch::Executable`.
