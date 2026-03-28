## Context

The upstream rebase updated 27 Redox flake inputs from Feb to Mar 2026. All tiers pass except tier-cross, which has 3 failing components: bootstrap (stale lockfile), virtio-fsd (API change), and redox-rt per-crate build (API change). The base workspace cargo build also needs the bootloader build plan regenerated.

Key constraint: Nix FOD reference check prevents generating Cargo.lock inside a fixed-output derivation when the source contains interpolated nix store paths (relibc-src path dep in bootstrap/Cargo.toml).

## Goals / Non-Goals

**Goals:**
- Get tier-cross to pass with all upstream sources from Mar 2026
- Minimal, targeted fixes — no refactoring beyond what's needed
- Keep the fix patterns reusable for future upstream rebases

**Non-Goals:**
- Upstreaming our patches to Redox
- Changing the per-crate build system architecture
- Updating the bootloader (separate target JSON restructuring)

## Decisions

### D1: Bootstrap lockfile — pre-commit generated lockfile checked into repo

Generate `nix/pkgs/infrastructure/bootstrap-Cargo.lock` offline using `cargo generate-lockfile` with the patched bootstrap source, then check it into git. The patchedSrc derivation copies this lockfile over the stale upstream one.

**Why not FOD?** Nix FOD reference check fails because patchedSrc interpolates `${relibc-src}` into Cargo.toml, creating a store-path reference in the derivation. The check fires even when the hash is correct on Nix 2.31+.

**Why not build-time regen?** fetchCargoVendor requires Cargo.lock to exist before vendoring. Can't delete-and-regen in the same derivation chain.

**Trade-off:** Checked-in lockfile must be manually regenerated when relibc deps change. Document this in a comment.

### D2: virtio-fsd — update for redox-scheme 0.11 API

The upstream redox-scheme 0.11 removed `SchemeState` and changed `SchemeSync` method signatures. Update our custom virtio-fsd source to match. Check the redox-scheme 0.11 changelog/source for the new API.

### D3: redox-rt per-crate build — add crate override

The per-crate `redox-rt` build fails because the base-build-plan resolves it from the relibc source path, but buildRustCrate can't handle the path correctly after upstream restructuring. Add a `extraCrateOverrides` entry for redox-rt that provides the correct source path.

## Risks / Trade-offs

- [Bootstrap lockfile drift] → Comment in bootstrap.nix documents regen procedure; future rebases will need to update it
- [virtio-fsd API changes may be incomplete] → Check all scheme handler methods against the new API, not just the ones that error
- [Bootloader deferred] → The bootloader target JSON restructuring is a separate change; current bootloader still builds from the old plan
