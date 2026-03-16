## 1. Per-Generation GC Root Naming

- [ ] 1.1 Rewrite `update_system_gc_roots()` in `system.rs` to create `gen-{N}-{pkg}` roots for the new generation without removing other generations' roots
- [ ] 1.2 Add migration logic: detect `system-*` roots, scan all existing generations, create `gen-{N}-*` roots for each, then remove old `system-*` roots
- [ ] 1.3 Unit tests: switch creates per-gen roots, old roots survive, migration works, no-migration-needed is a no-op

## 2. Delete Generations

- [ ] 2.1 Implement `delete_generations()` in `system.rs` — parse selectors (`+N`, `Nd`, ID list, `old`), compute protected set (current + boot-default), remove generation dirs and `gen-{N}-*` GC roots
- [ ] 2.2 Add `SystemCommand::DeleteGenerations` CLI variant in `main.rs` with `--dry-run` flag and selector argument
- [ ] 2.3 Unit tests: delete by ID, keep last N, older than N days, protect current, protect boot-default, dry run, nothing to delete

## 3. System GC Convenience Command

- [ ] 3.1 Implement `system_gc()` in `system.rs` — calls `delete_generations()` then `store::run_gc()`, passes through `--keep` and `--dry-run`
- [ ] 3.2 Add `SystemCommand::Gc` CLI variant in `main.rs` with `--keep N` and `--dry-run` flags
- [ ] 3.3 Unit tests: combined prune+sweep, dry run shows both phases, default deletes all old

## 4. Integration Tests

- [ ] 4.1 Add GC root assertions to the existing rebuild-generations test profile: verify `gen-{N}-*` roots exist after switch/rollback
- [ ] 4.2 VM integration test: rebuild twice, run `snix system gc --keep 1 --dry-run`, verify correct generations listed for deletion and store paths listed for sweep
