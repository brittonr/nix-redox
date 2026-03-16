## Context

The Nix store GC (`snix store gc`) works correctly: mark-and-sweep from GC roots. The generation system (`snix system switch/rollback/generations`) also works correctly. But the GC root lifecycle connecting them is broken — `update_system_gc_roots()` replaces all `system-*` roots with only the current generation's packages on every switch/rollback. Old generations' store paths become unrooted and get swept on the next GC.

NixOS solves this by making every profile generation a GC root. Generations are deleted explicitly (`nix-env --delete-generations`), which removes the root symlinks. Then `nix-store --gc` sweeps the now-unrooted paths. Two operations, clean separation.

## Goals / Non-Goals

**Goals:**
- Every generation's store paths are protected from GC until the generation is explicitly deleted
- Users can prune old generations with flexible selectors (`+N`, `Nd`, specific IDs)
- A single convenience command (`snix system gc`) handles the prune-then-sweep sequence
- Rollback to any non-deleted generation always works

**Non-Goals:**
- Automatic/scheduled GC (user-initiated only)
- Cross-generation deduplication or hardlinking (store paths are already content-addressed)
- GC of the build sandbox or cache directories
- Profile-level GC (only system generations, not user profiles)

## Decisions

### 1. Per-generation GC root naming: `gen-{N}-{pkg}`

Each generation gets its own set of GC roots named `gen-{N}-{pkg_name}`, where N is the generation ID. This replaces the current `system-{pkg_name}` scheme.

**Why not a single root per generation?** We don't have a single "system" store path per generation (like NixOS's `/nix/store/...-nixos-system-...`). Our manifest lists individual package store paths. Per-package roots reuse the existing GcRoots infrastructure without changes.

**Why not keep `system-{pkg}` and just stop removing them?** Package names aren't unique across generations — generation 1 might have `base` at `/nix/store/aaa-base` and generation 3 might have `base` at `/nix/store/bbb-base`. The root name must encode the generation to avoid overwrites.

### 2. Migration: re-root existing generations on first switch

On the first switch after upgrade, the old `system-*` roots are replaced with `gen-{N}-*` roots for ALL existing generations (not just current). This is a one-time migration that scans `/etc/redox-system/generations/` and roots every generation's packages.

**Why not a separate migration command?** Users shouldn't need to remember to run a migration. The switch path already calls `update_system_gc_roots()`, so it's the natural place.

### 3. Separate delete-generations from store GC

`snix system delete-generations` removes generation directories and their `gen-{N}-*` GC roots but does NOT touch the store. `snix store gc` sweeps unreferenced paths. `snix system gc` is a convenience wrapper that does both.

**Why separate?** Matches NixOS. Lets users inspect what would be freed (`delete-generations --dry-run` then `store gc --dry-run`) before committing. Store GC also collects paths unrelated to generations (e.g., manually fetched packages with removed roots).

### 4. Selector syntax matches NixOS conventions

- `+N` — keep the N most recent generations, delete the rest
- `Nd` — delete generations older than N days
- `1 3 5` — delete specific generation IDs by number
- `old` — delete all but the current generation

**Why match NixOS?** Users familiar with `nix-collect-garbage -d` or `nix-env --delete-generations` get the same mental model. No reason to invent new syntax.

### 5. Current generation is never deletable

`delete-generations` refuses to delete the currently active generation (the one in `/etc/redox-system/manifest.json`). Also refuses to delete the boot-default generation if one is set and differs from current.

## Risks / Trade-offs

**More GC roots accumulate** → Each generation adds ~25 root symlinks (one per package). 100 generations = 2500 symlinks in `/nix/var/snix/gcroots/`. Acceptable — these are tiny symlinks, and `list_roots()` is a directory scan that handles thousands easily.

**Migration on first switch is O(generations × packages)** → Scanning all generations to create roots. With typical generation counts (<100) and package counts (<50), this is <5000 symlink creations — under a second.

**Breaking change: root naming** → Any tooling inspecting `system-*` roots breaks. Mitigated by the migration happening automatically. No external consumers exist today.

**Boot-default protection** → If boot-default points to generation 5 and user runs `delete-generations old`, generation 5 must be preserved even if it's not the current running generation. Failure to protect it would break the next reboot.
