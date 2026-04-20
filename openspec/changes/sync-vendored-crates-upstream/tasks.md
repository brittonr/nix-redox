## 1. Build the inventory

- [x] 1.1 Create `openspec/changes/sync-vendored-crates-upstream/evidence/crate-inventory.md` and enumerate vendored crates, forked crate sources, and patched vendored dependencies across `nix/pkgs/`, `snix-redox/`, and source-bundle derivations.
- [x] 1.2 Record for each site: owner, local carry type, current upstream candidate, guest-facing classification, and required validation path.
- [x] 1.3 Link the inventory from the change artifacts and keep it updated as dispositions change.

## 2. Classify carries and choose implementation order

- [x] 2.1 Mark each inventory entry as `update`, `keep-local`, or `defer` with a short reason and retry trigger.
- [x] 2.2 Pick an initial batch of low-risk `update` candidates from independent non-`snix-redox` carry sites.
- [x] 2.3 Reserve `snix-redox` and other dual-use guest-facing workspaces for a separate later batch with explicit validation notes.

## 3. Apply upstream syncs

- [x] 3.1 Update each selected independent carry site in the initial batch from local carry to upstream source and remove unnecessary local vendor patches.
- [x] 3.2 Regenerate all lockfiles, vendor hashes, source-bundle metadata, and other derived state affected by each sync, verify the updated package or source bundle still resolves dependencies offline through the normal vendoring path, and confirm `.cargo/config.toml` still points at the actual vendored directory layout (`vendor/source-registry-0`, `vendor/source-git-0`, or equivalent).
- [ ] 3.3 If any surviving patch can run through both packaged-build and source-bundle paths, make it idempotent or add explicit prior-application detection.
- [ ] 3.4 Refresh the `snix-upstream-source.nix` / local `snix-redox/upstream` input path as needed, then apply the isolated `snix-redox` batch, including `snix-redox/regenerate-build-plan.sh` and any source-bundle metadata refresh required by the new graph; do not treat cargo-only green results as sufficient.

## 4. Validate and record exceptions

- [ ] 4.1 Run the mapped host-only validation for each host-only updated candidate and keep only the syncs that preserve required behavior.
- [x] 4.2 Run the mapped guest-facing validation for each guest-facing or dual-use updated candidate, including focused VM or self-hosting coverage where the inventory requires it.
- [x] 4.3 For each `keep-local` or `defer` entry, document the blocker, dependent package paths, and retry trigger in the inventory.
- [x] 4.4 Update repo docs or maintenance notes so future crate-sync work can reuse the inventory, exception records, and validation rules by linking the inventory from the change artifacts and recording the reusable inventory/validation rule in `AGENTS.md`.
