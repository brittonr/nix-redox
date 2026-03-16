## Why

`snix store gc` deletes store paths that aren't protected by GC roots. But `update_system_gc_roots()` only roots the *current* generation's packages — old generations lose their roots on every switch/rollback. Running `snix store gc` after a few switches silently breaks rollback by deleting store paths that old generation manifests still reference. There's also no way to prune old generations themselves — `/etc/redox-system/generations/` grows without bound.

## What Changes

- **Fix per-generation GC rooting**: switch/rollback adds `gen-{N}-{pkg}` roots for the new generation *without removing old generations' roots*. Every generation stays rollback-safe until explicitly deleted.
- **Add `snix system delete-generations`**: explicitly remove generation directories and their GC roots. Supports `+N` (keep last N), `Nd` (older than N days), specific IDs, and `old` (all but current).
- **Add `snix system gc`**: convenience command that prunes generations then runs store GC in the correct order. Equivalent to `delete-generations` + `store gc`.
- **BREAKING**: GC root naming changes from `system-{pkg}` to `gen-{N}-{pkg}`. First switch after upgrade re-roots all existing generations under the new scheme.

## Capabilities

### New Capabilities
- `generation-gc`: Generation pruning and integrated garbage collection — deleting old generations, removing their GC roots, and sweeping unreferenced store paths.

### Modified Capabilities
- `generation-management`: GC root lifecycle changes — switch/rollback must create per-generation roots instead of replacing a single set of current-only roots.

## Impact

- `snix-redox/src/system.rs`: `update_system_gc_roots()` rewritten, new `delete_generations()` function, new `system_gc()` function
- `snix-redox/src/store.rs`: no changes (mark-and-sweep already correct)
- `snix-redox/src/main.rs`: new `SystemCommand::DeleteGenerations` and `SystemCommand::Gc` CLI variants
- `snix-redox/src/activate.rs`: calls updated `update_system_gc_roots_pub()` (signature unchanged)
- Existing generation/rollback integration tests need GC root assertions added
