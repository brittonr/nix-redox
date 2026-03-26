## Context

snix-redox pulls upstream snix crates from a pinned git commit via `snix-upstream-source.nix`. The derivation fetches the monorepo, extracts 10 crate directories, and applies Redox-specific patches (systems.rs, pub visibility for builder/fetchurl APIs, feature gating for Linux-only modules). The current pin is `6f7069cd68` (2026-03-22).

Upstream landed 3 commits since our pin:
- `d048106f03` — Fix additional_files keys in structured_attrs (relative to root)
- `2cbfabf90d` — Test fix for fetchtarball eval test (test-only)
- `34604636d7` — Fix SnixStoreFS::list() tokio runtime context (castore/fs, not used by us)

Plus ~30 commits between our previous pin (`2207a074ae`, 2026-03-19) and current pin that we already picked up. The eval performance improvements (observer dyn dispatch, NixAttrs unboxing, path import cache) landed between 2026-03-09 and 2026-03-10 and are already in our current pin.

## Goals / Non-Goals

**Goals:**
- Bump to `34604636d7` to pick up the structured_attrs additional_files fix
- Verify all Redox patches still apply cleanly on the new code
- Verify `nix flake check` passes (host-side tests)
- Verify VM functional tests pass (guest-side)

**Non-Goals:**
- Picking up new upstream API surface beyond what we already use
- Changing snix-redox module structure
- Adjusting workspace.dependencies versions (only if upstream changed them)

## Decisions

**Pin target: `34604636d7`** — Latest canon commit as of 2026-03-26. The structured_attrs fix is the only functionally relevant change for us (affects `derivation_into_build_request` which we call from `local_build.rs`). The other two commits are a test fix and a castore/fs fix we don't use.

**Patch verification approach:** Run the existing `snix-upstream-source.nix` derivation with the new rev/hash. If sed commands fail (pattern not found), the build errors out. Check each patch target file manually if sed patterns changed upstream.

**Workspace deps:** Compare upstream `Cargo.toml` workspace dependencies at the new pin against our copied versions. Only update if upstream changed a version.

## Risks / Trade-offs

**[Patch drift]** → Upstream may have refactored files our sed patches target. Mitigation: The sed commands fail loudly if patterns don't match. Manual inspection of `glue/src/lib.rs`, `glue/src/fetchurl.rs`, `glue/src/builder/mod.rs`, `eval/src/systems.rs` at the new commit.

**[Feature default changes]** → Upstream occasionally changes `default = [...]` in Cargo.toml. Our sed disables cloud/fuse/tonic-reflection defaults. Mitigation: Check if the default feature lists changed between pins.

**[store Cargo.toml defaults]** → Between `eee4779` and `2207a07`, upstream changed store defaults from including `otlp` to `["cloud", "fuse", "tonic-reflection"]`. Another change is possible. Mitigation: Verify the sed pattern still matches.
