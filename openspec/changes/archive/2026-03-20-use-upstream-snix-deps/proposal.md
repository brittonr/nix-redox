## Why

snix-redox vendors ~34k LOC across two upstream crates and reimplements ~2,300 LOC of logic that exists in upstream snix-glue (`KnownPaths`, `derivation_builtins`, `fetcher_builtins`, `EvalIO`). Every upstream bug fix, new builtin, protocol update, and NAR format improvement must be manually cherry-picked. Meanwhile, tokio works on Redox — irohd proves it with tokio 1.50 (`rt-multi-thread`, `net`, `fs`, `process`), mio, reqwest, and 314 crates all cross-compiling and running. This means the full snix-glue stack (which requires tokio) is viable.

Switching to upstream snix crates with Nix-applied patches eliminates vendored forks, replaces reimplemented eval/build glue with upstream's tested implementations, and keeps us current with upstream automatically.

## What Changes

- Replace `nix-compat-redox/` (vendored fork, 17k LOC) with upstream `nix-compat`
- Replace `snix-eval-vendored/` (vendored fork, 17k LOC) with upstream `snix-eval`, patched at build time to add `"redox"` system string
- Replace `snix-redox/src/derivation_builtins.rs` (516 LOC) with upstream `snix-glue`'s derivation builtins
- Replace `snix-redox/src/fetchers.rs` fetcher builtins (983 LOC) with upstream `snix-glue`'s fetcher builtins
- Replace `snix-redox/src/known_paths.rs` (85 LOC) with upstream `snix-glue`'s `KnownPaths`
- Replace `snix-redox/src/snix_io.rs` `EvalIO` impl (694 LOC) with upstream `snix-glue`'s `SnixStoreIO` (adapted for Redox store layout)
- Remove `nix-compat-derive/` local copy
- Add `snix-glue`, `snix-store`, `snix-castore`, `snix-build` as upstream dependencies
- Add `tokio` runtime dependency (already proven on Redox via irohd)
- Update Nix build expressions to fetch upstream monorepo, extract needed crates, apply patches
- Regenerate build plan (crate count will increase from ~161 to ~400+)

## Capabilities

### New Capabilities
- `upstream-snix-deps`: Switch snix-redox from vendored forks and reimplemented glue to upstream snix crates (nix-compat, snix-eval, snix-glue, snix-store, snix-castore, snix-build) with Nix-applied patches at build time.

### Modified Capabilities

## Impact

- `snix-redox/Cargo.toml` — dependency declarations change from local paths to upstream crates; tokio added
- `snix-redox/nix-compat-redox/` — deleted (17k LOC)
- `snix-redox/nix-compat-derive/` — deleted
- `snix-redox/snix-eval-vendored/` — deleted (17k LOC)
- `snix-redox/src/derivation_builtins.rs` — deleted, replaced by upstream snix-glue
- `snix-redox/src/fetchers.rs` — deleted (builtin fetchers from upstream), fetch_to_store/verify_fetch_hash kept or adapted
- `snix-redox/src/known_paths.rs` — deleted, replaced by upstream snix-glue
- `snix-redox/src/snix_io.rs` — rewritten to wrap upstream `SnixStoreIO` or implement `EvalIO` using upstream services
- `snix-redox/src/eval.rs` — rewritten to use upstream `add_derivation_builtins`, `add_fetcher_builtins`, `add_import_builtins`
- `snix-redox/src/local_build.rs` — adapted to use upstream build service interface where applicable; Redox sandbox integration retained
- `snix-redox/patches/0001-systems-add-redox-os-support.patch` — retained, applied by Nix
- `nix/pkgs/userspace/snix.nix` and `snix-source-bundle.nix` — rewritten for upstream sources
- `nix/flake-modules/packages.nix` — snix build gains `extraCrateOverrides` for upstream deps needing Redox patches (similar pattern to irohd)
- Build plan grows from ~161 to ~400+ crates; disk/memory usage increases
- All 607 existing unit tests must continue to pass
- Redox-specific code (build_proxy, stored, profiled, sandbox, scheme daemons) remains unchanged
