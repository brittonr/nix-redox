## Why

We're pinned to upstream snix commit `eee4779` from 2026-02-05 — about 6 weeks behind. The upstream project has landed ~80 commits since then including a 20% eval performance improvement (observer dyn dispatch removal), a path import cache, API refactors to `from_absolute_path_full` and `KnownPaths`, bugfixes (`builtins.fetch{url,tarball}` now correctly returns strings not paths), dropped unused feature flags from `snix-store` and `snix-build`, and directory deduplication in castore imports.

Bumping now keeps our patch surface small and picks up free perf wins before we start deeper integration work (BuildService, PathInfoService, binary cache).

## What Changes

- Update the snix upstream pin in `snix-upstream-source.nix` from `eee4779` to latest canon (circa `2207a074ae` / 2026-03-19)
- Update the `fetchgit` hash to match the new commit
- Re-verify and update all sed/patch transforms in `snix-upstream-source.nix` against the new source (feature flag defaults may have changed upstream — e.g. `snix-store` already dropped `otlp` from defaults)
- Update workspace dependency versions in `snix-redox/Cargo.toml` to match upstream's new `[workspace.dependencies]`
- Fix compile errors in `snix-redox/src/` caused by upstream API changes:
  - `KnownPaths` switched to `hashbrown::HashMap` — adapt call sites
  - `from_absolute_path_full` signature changed (returns `&Path` not platform-specific) — audit 25+ call sites using `from_absolute_path` (this function itself is unchanged, but `from_absolute_path_full` callers in `flake.rs` need checking)
  - `snix-build` dropped `snix-tracing` dep — verify our feature gates still compile
  - `snix-eval` now has `mimalloc` behind a feature flag — ensure we don't accidentally enable it
- Update vendor hash in `snix.nix` and `snix-source-bundle.nix` if dependency versions changed
- Run the full 562-test `snix-redox` test suite to verify no regressions

## Capabilities

### New Capabilities
- `snix-upstream-bump`: Covers the version pin update, patch re-application, workspace dep sync, and API migration required to track upstream snix canon branch.

### Modified Capabilities
- `upstream-snix-deps`: The existing spec covers how we extract and patch upstream crates. The pin commit and patch set will change, but the requirements (extract crates, apply Redox systems patch, gate Linux-only features) remain the same — no spec-level behavior change.

## Impact

- `nix/pkgs/infrastructure/snix-upstream-source.nix` — new commit, hash, possibly updated sed commands
- `snix-redox/Cargo.toml` — workspace dependency version bumps
- `snix-redox/src/*.rs` — compile fixes for API changes (primarily `KnownPaths` hashbrown migration, `Evaluation` builder API if changed)
- `nix/pkgs/userspace/snix.nix` — vendor hash update if deps changed
- `nix/pkgs/infrastructure/snix-source-bundle.nix` — vendor hash update if deps changed
- No changes to Redox-specific modules (stored, profiled, build_proxy, sandbox, activate, etc.) unless upstream changed the traits they depend on
