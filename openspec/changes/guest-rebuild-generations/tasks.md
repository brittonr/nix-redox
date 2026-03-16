## 1. Audit and fix snix system commands for Redox compatibility

- [x] 1.1 Grep snix-redox/src/rebuild.rs, system.rs, activate.rs for `canonicalize()` calls and fix any that return `file:/path` on Redox
- [x] 1.2 Verify `evaluate_config()` in rebuild.rs works with the default configuration.nix format (test with `snix eval --file /etc/redox-system/configuration.nix` in an existing VM test)
- [x] 1.3 Verify `/nix/cache/packages.json` (the cache index) exists on development-profile images; if not, add it to the build module's generated files
- [x] 1.4 Check that `resolve_packages()` in rebuild.rs handles the case where `packages` is `None` (no package changes, only config changes like hostname)
- [x] 1.5 Fix any compilation issues found during audit (update Cargo.lock if needed)

## 2. Create the test profile

- [x] 2.1 Create `nix/redox-system/profiles/rebuild-generations-test.nix` extending the development profile
- [x] 2.2 Write the Ion test script using FUNC_TEST protocol — Phase 1: pre-flight checks (configuration.nix exists, manifest.json exists, snix binary exists)
- [x] 2.3 Phase 2: show-config test — run `snix system show-config` and verify it exits successfully
- [x] 2.4 Phase 3: dry-run rebuild — run `snix system rebuild --dry-run` and verify no files changed
- [x] 2.5 Phase 4: modify configuration.nix hostname and rebuild — verify `/etc/hostname` updated and new generation created
- [x] 2.6 Phase 5: list generations — run `snix system generations` and verify output lists at least 2 generations
- [x] 2.7 Phase 6: rollback — run `snix system rollback` and verify hostname reverted to original value
- [x] 2.8 Phase 7: verify rollback generation — check that generation 3 exists and manifest matches pre-rebuild state
- [x] 2.9 Phase 8: package addition test — modify configuration.nix to add a package, rebuild, verify it appears in manifest

## 3. Wire into flake

- [x] 3.1 Add `rebuild-generations-test` app to `nix/flake-modules/apps.nix` using the same pattern as other test apps
- [x] 3.2 Add the profile to the redox-system module so it builds a disk image with the test profile
- [x] 3.3 Verify the test profile evaluates without errors: `nix build .#rebuild-generations-test-diskImage` (or equivalent)

## 4. Run and debug

- [x] 4.1 Boot the test image and capture serial output — identify first failures
- [x] 4.2 Fix bugs in snix-redox rebuild/system code discovered by the tests
- [x] 4.3 Re-run until all Phase 1-4 tests pass (pre-flight, show-config, dry-run, hostname rebuild)
- [x] 4.4 Re-run until all Phase 5-7 tests pass (generations list, rollback, rollback verification)
- [x] 4.5 Re-run until Phase 8 passes (package addition via rebuild)
- [x] 4.6 Run the full test suite clean from a fresh image to confirm all tests pass end-to-end

## 5. Integration

- [x] 5.1 Update README.md test counts table with the new suite
- [x] 5.2 Run existing test suites (functional-test, boot-test) to confirm no regressions
- [ ] 5.3 Commit with descriptive message summarizing test count and any snix fixes
