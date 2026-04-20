## Context

Redox uses several vendoring patterns today:
- normal `fetchCargoVendor` or unit2nix vendoring for offline builds
- forked crate sources or upstream workspaces copied into the tree or prepared in Nix derivations
- one-off patches applied inside vendored dependency trees when Redox support is missing upstream

Known carry sites already visible from the tree include:
- `nix/pkgs/infrastructure/snix-upstream-source.nix` — pinned upstream snix workspace plus Redox-specific sed/patch carry, pregenerated proto descriptors, and shared source-bundle interaction
- `nix/pkgs/userspace/pkgutils.nix` — crates.io `ring` replaced with the Redox git fork because the crates.io tarball lacks pregenerated assembly inputs needed for Redox
- `nix/pkgs/system/base.nix` — vendored `acpi` crate patched after `vendor-combined` creation, with checksum reset
- `nix/pkgs/userspace/orbital.nix` — git/path redirection and manifest rewriting to line local sources up with the vendored dependency set

Those carries are spread across `nix/pkgs/userspace/`, `nix/pkgs/system/`, `nix/pkgs/infrastructure/`, `snix-redox/`, and package-specific source-bundle derivations. Some are clearly still needed for Redox. Some may now be stale because upstream absorbed the fix or because a newer upstream release would work. Blindly updating all vendored crates at once would create too much breakage and hide which local carries still matter.

## Goals / Non-Goals

**Goals:**
- make vendored-crate carries visible and reviewable
- define a repeatable rule for when to switch back to upstream
- update low-risk carries first and leave strong evidence for the exceptions
- keep offline and self-hosting build paths reproducible after crate-source changes

**Non-Goals:**
- bulk-update every Cargo dependency in the repo
- remove vendoring itself; offline builds remain required
- force guest-level validation for packages that are demonstrably host-only
- redesign package infrastructure unrelated to crate-source maintenance
- treat pure unit2nix auto-vendored packages with no local divergence as first-class targets unless they become explicit carry sites during this work
- pull in non-crate vendor carries such as C-library compatibility stubs unless they are directly attached to a Rust crate-source sync

## Decisions

### 1. Work per vendored-source site, not by global crate name

**Choice:** Treat each package or workspace that carries a vendored crate, fork, or vendor patch as its own sync unit. A site enters scope when its package path contains an explicit local divergence marker such as `gitSources`, a non-registry crate source replacement, vendored-content patching (`sed`, `substituteInPlace`, custom patch script), or manual `.cargo-checksum.json` reset.

**Rationale:** The same upstream crate can appear under very different constraints in different package paths. `snix-redox` upstream workspace carries, package-local vendor replacements like `pkgutils`, and patched vendored crates inside larger workspaces each need different validation and rollback. A per-site approach keeps changes reviewable and lets us keep one package local without blocking another from moving upstream.

**Alternative considered:** Do a repo-wide version sweep by crate name. Rejected because it would mix host-only, guest-native, and self-hosting paths into one high-risk batch.

### 2. Require an explicit disposition before editing package state

**Choice:** Build an inventory first in [`evidence/crate-inventory.md`](./evidence/crate-inventory.md), then assign each carry one of three dispositions: `update`, `keep-local`, or `defer`.

**Rationale:** User asked for "where it makes sense," which implies selection criteria. Writing the disposition before changing source pins prevents cargo-edit churn without a reason and gives us a durable list of exceptions instead of tribal knowledge. Keeping the first inventory under change-local evidence makes the initial pass easy to review without committing yet to a long-lived docs format.

**Alternative considered:** Opportunistic updates while touching packages. Rejected because the repo already has enough scattered vendor lore.

### 3. Keep upstream sync and validation tied together

**Choice:** Every crate-source update must name its smallest proving validation up front, then run broader suites only when the touched path reaches guest-native or self-hosting behavior. Any package that appears in a guest source bundle, VM profile, or self-hosting input path counts as guest-facing even if it also builds or runs on the host.

**Rationale:** Some carries only affect host tools; others change Redox runtime behavior or guest source bundles. Tying validation to blast radius keeps the work moving without under-testing guest-facing updates. The explicit dual-use rule avoids false "host-only" classification for packages like `snix-redox` inputs.

**Alternative considered:** Run full `nix flake check` plus full self-hosting for every update. Rejected because it is too slow for exploratory pruning and would discourage small safe syncs.

### 4. Preserve reproducibility metadata as part of each sync

**Choice:** Treat Cargo.lock changes, vendor hashes, build-plan regeneration, and source-bundle metadata as part of the crate-source change, not follow-up cleanup. For `snix-redox`-adjacent updates, this includes the concrete regeneration sequence already known to be failure-prone: update the upstream source derivation, refresh any local `snix-redox/upstream` workflow dependency if needed, and rerun `snix-redox/regenerate-build-plan.sh` so both build-plan files track the new graph.

**Rationale:** In this repo, stale derived metadata is a common false failure mode. A crate update that leaves the old vendor hash or old unit2nix plan behind is not actually reviewable. `snix-redox` is the clearest example because source updates can look green under plain cargo while Nix still consumes stale build-plan metadata.

**Alternative considered:** Land source updates first, repair metadata later. Rejected because it breaks offline build guarantees and creates noisy bisects.

## Risks / Trade-offs

- **[Large multi-workspace blast radius]** → Start with small independent carries; avoid mixing `snix-redox`, base system, and unrelated userspace packages in one implementation slice.
- **[False confidence from host-only checks]** → Require guest/self-hosting coverage whenever source bundles or Redox-native packages move.
- **[Upstream version churn breaks local patches]** → Prefer replacing carries entirely; if a carry remains, record exact blocker and retry trigger instead of half-updating it.
- **[Patch double-apply on shared source trees]** → Any patch that may run in both packaged and source-bundle flows must stay idempotent or grow explicit conflict detection; `patch-snix-fetcher-no-tls-panic.py` is current example.
- **[Metadata drift causes misleading failures]** → Regenerate lockfiles, vendor hashes, and build plans in same task as the source change.

## Migration Plan

Known carry-site starting classifications:

| Site | Classification | Expected validation floor |
|---|---|---|
| `nix/pkgs/system/base.nix` / vendored `acpi` patch | guest-native | focused VM boot or equivalent initfs coverage |
| `nix/pkgs/userspace/pkgutils.nix` / `ring` fork | guest-native, probable `keep-local` until upstream release tarballs ship needed pregenerated assembly | host cross-build plus guest package smoke |
| `nix/pkgs/userspace/orbital.nix` / git-path rewrite | guest-native (graphical) | graphical VM boot |
| `nix/pkgs/infrastructure/snix-upstream-source.nix` | dual-use (host + guest bundle) | host build plus self-hosting coverage |

Low-risk means: single-package scope, no shared guest source bundle, no self-hosting build-plan regeneration, and no graphical-boot dependency. Sites that miss any of those checks move into isolated later batches.

1. Inventory current vendored/forked/patch-carried crate sites in `evidence/crate-inventory.md`.
2. Assign each site a disposition and validation path.
3. Implement low-risk independent `update` sites first, keeping `snix-redox` and other dual-use workspaces isolated in their own later batch.
4. Leave `keep-local` and `defer` sites with documented blocker evidence.
5. Revisit deferred sites when retry triggers occur.

Rollback is straightforward per site: restore previous source pin, vendor patch, and derived metadata for the affected package.

## Open Questions

- None blocking for initial implementation. After the first batch lands, we can decide whether `evidence/crate-inventory.md` should be promoted into longer-lived docs.
