## Context

snix-redox uses upstream snix crates as workspace members extracted by a Nix derivation (`snix-upstream-source.nix`). The extraction applies sed transforms and patches to disable Linux-only features (FUSE, bwrap, OCI, cloud/bigtable, aws-lc TLS) and add Redox to the eval systems list. We're pinned at commit `eee4779` (2026-02-05).

The upstream snix project moves fast — ~80 commits in the 6 weeks since our pin. The workspace layout and crate boundaries haven't changed, but internal APIs have evolved: `KnownPaths` uses hashbrown, `from_absolute_path_full` changed its return type, eval got performance work, and several feature flag defaults shifted.

We have 562 tests in `snix-redox` that exercise both our code and the upstream crate APIs, giving us confidence in detecting breakage.

## Goals / Non-Goals

**Goals:**
- Update snix pin to latest canon (~2026-03-19)
- Re-apply all existing patches against the new source
- Fix all compile errors from upstream API changes
- Pass the full snix-redox test suite (host-side `cargo test`)
- Pass the cross-compilation build (`nix build .#snix-redox`)
- Keep the patch surface as small as possible — if upstream changed defaults in our favor, drop the corresponding sed

**Non-Goals:**
- Adopting new upstream features (BuildService, redb PathInfoService, etc.) — that's separate work
- Upstreaming our Redox systems patch — nice to do eventually, not part of this change
- Changing any snix-redox module logic — this is a mechanical version bump, not a refactor

## Decisions

### Pin selection: latest canon HEAD vs tagged release
Pick latest canon HEAD. snix doesn't do tagged releases — canon is the stable branch. Picking HEAD maximizes the time before the next bump. If a specific commit is broken, bisect backward.

### Patch strategy: sed transforms vs patch files
Keep the current approach: sed transforms for Cargo.toml feature changes, a single patch file for the systems.rs change. The sed approach is fragile but the Cargo.toml lines it targets are stable patterns. If an sed fails (line no longer matches), the build breaks loudly. Convert to patch files only if sed starts silently doing nothing.

**Validate each sed**: After bumping, check if upstream already made the change we were sed-ing. For example, `snix-store` dropped `otlp` from defaults in commit `8fb7605` — our sed that strips `otlp` from defaults may need updating to match the new default set.

### Workspace dep sync: manual vs automated
Manual sync. Copy the `[workspace.dependencies]` section from upstream's root `Cargo.toml` into our `snix-redox/Cargo.toml`. We only need deps that our workspace members actually use — but keeping the full set prevents version conflicts when upstream crates reference workspace deps we don't list.

### API migration: fix-forward vs compatibility shims
Fix-forward. Upstream API changes are small (hashbrown `HashMap` import, `from_absolute_path_full` return type). Direct migration is cleaner than shimming. Our 25+ `from_absolute_path` call sites use the unchanged `from_absolute_path` function, not the `_full` variant — so most won't need changes.

## Risks / Trade-offs

**[Upstream API break we didn't spot in commit log]** → The test suite catches this. Run `cargo test` and `cargo check --target x86_64-unknown-redox` before declaring done.

**[sed targets changed]** → Each sed in `snix-upstream-source.nix` matches a specific string literal. If the string changed upstream, `sed -i` silently does nothing, and the build fails later with a compile error. Mitigation: after bumping, verify each sed actually modified its target file (check the build log or run the seds manually).

**[Vendor hash cascade]** → Changing workspace dep versions changes the Cargo.lock, which changes the vendor hash. Both `snix.nix` and `snix-source-bundle.nix` reference the same vendor setup. Use dummy hash `sha256-0000...` to get the real hash from the error message.

**[hashbrown version mismatch]** → `KnownPaths` now uses `hashbrown::HashMap`. If our `Cargo.toml` doesn't list `hashbrown` (or lists a different version), we get compile errors. Check upstream's hashbrown version and add it to workspace deps.
