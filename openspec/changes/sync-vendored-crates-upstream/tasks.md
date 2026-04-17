## 1. Build the inventory

- [ ] 1.1 Create `openspec/changes/sync-vendored-crates-upstream/evidence/crate-inventory.md` and enumerate vendored crates, forked crate sources, and patched vendored dependencies across `nix/pkgs/`, `snix-redox/`, and source-bundle derivations.
- [ ] 1.2 Record for each site: owner, local carry type, current upstream candidate, guest-facing classification, and required validation path.
- [ ] 1.3 Link the inventory from the change artifacts and keep it updated as dispositions change.

## 2. Classify carries and choose implementation order

- [ ] 2.1 Mark each inventory entry as `update`, `keep-local`, or `defer` with a short reason and retry trigger.
- [ ] 2.2 Pick an initial batch of low-risk `update` candidates from independent non-`snix-redox` carry sites.
- [ ] 2.3 Reserve `snix-redox` and other dual-use guest-facing workspaces for a separate later batch with explicit validation notes.

## 3. Apply upstream syncs

- [ ] 3.1 Update the first selected independent carry site from local carry to upstream source and remove unnecessary local vendor patches.
- [ ] 3.2 Regenerate all lockfiles, vendor hashes, and other derived metadata affected by that sync.
- [ ] 3.3 If any surviving patch can run through both packaged-build and source-bundle paths, make it idempotent or add explicit prior-application detection.
- [ ] 3.4 Apply the isolated `snix-redox` batch, including `snix-redox/regenerate-build-plan.sh` and any source-bundle metadata refresh required by the new graph; do not treat cargo-only green results as sufficient.

## 4. Validate and record exceptions

- [ ] 4.1 Run the mapped host-only or guest-facing validation for each updated candidate and keep only the syncs that preserve required behavior.
- [ ] 4.2 For each `keep-local` or `defer` entry, document the blocker, dependent package paths, and retry trigger in the inventory.
- [ ] 4.3 Update repo docs or maintenance notes so future crate-sync work can reuse the inventory, exception records, and validation rules.
