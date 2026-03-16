## 1. Add --local flag and auto-routing logic

- [x] 1.1 Add `--local` flag to `SystemCommand::Rebuild` in main.rs (bool, mutually exclusive with `--bridge`)
- [x] 1.2 Create `auto_rebuild()` in rebuild.rs that: parses config, checks if packages changed (Some + non-empty), checks bridge availability (`/scheme/shared/requests` is_dir), and routes to bridge or local
- [x] 1.3 Update main.rs dispatch: `--bridge` → bridge, `--local` → local, neither → `auto_rebuild()`
- [x] 1.4 In `auto_rebuild()`: if packages changed and no bridge, emit the error message with instructions and return Err
- [x] 1.5 Treat `packages = []` (empty list) the same as `packages` absent — no package change detected

## 2. Update local rebuild path

- [x] 2.1 In `rebuild()`, add an optional `force_local` parameter (or restructure so the caller decides). When called from auto-routing without package changes, skip the package resolution step entirely (no packages.json lookup needed)
- [x] 2.2 When called with `--local` and packages present, keep the existing JSON resolution path but print a warning that results may be incomplete

## 3. Update tests

- [x] 3.1 Update rebuild-generations-test.nix Phase 8 to pass `--local` flag for the package addition test (since the test VM has no bridge)
- [x] 3.2 Add a Phase 3b test: `snix system rebuild` with unchanged config and no bridge should succeed (auto-routes to local for config-only)
- [x] 3.3 Verify dry-run still works with auto-routing (`snix system rebuild --dry-run` with no package changes)

## 4. Update documentation

- [x] 4.1 Update the generated configuration.nix comments in `generated-files.nix` to explain: config-only changes use local path, package changes need bridge
- [x] 4.2 Update README.md rebuild section to describe the auto-routing behavior

## 5. Build and validate

- [x] 5.1 Compile snix-redox and verify no errors
- [x] 5.2 Build the rebuild-generations-test disk image
- [x] 5.3 Run rebuild-generations-test — all 26 tests pass (added auto-route test)
- [x] 5.4 Run boot-test and functional-test — no regressions
- [ ] 5.5 Commit
