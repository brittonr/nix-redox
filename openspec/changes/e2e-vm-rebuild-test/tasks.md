## 1. Test Profile

- [x] 1.1 Create `nix/redox-system/profiles/e2e-rebuild-test.nix` with environment.etc entries, activation scripts with deps, and startup script runner
- [x] 1.2 Declare initial etc files (motd, custom config) and activation scripts (mkdir + write marker with dependency ordering) in module config
- [x] 1.3 Include a `configuration.nix` on the disk image that the test can modify for rebuild

## 2. Test Script

- [x] 2.1 Create `nix/redox-system/test-scripts/21-e2e-rebuild.ion` with FUNC_TEST protocol
- [x] 2.2 Phase 1 — verify initial state: etc files exist with correct content, activation markers present
- [x] 2.3 Phase 2 — modify config and rebuild: change hostname, add new etc file entry, rebuild via `--config`, verify all changes applied
- [x] 2.4 Phase 3 — no-op rebuild: run rebuild again with same config, verify no generation created
- [x] 2.5 Phase 4 — rollback: run `snix system switch --rollback`, verify original hostname restored, new generation created

## 3. Flake Integration

- [x] 3.1 Add e2eRebuildTestSystem and e2eRebuildTest to `nix/flake-modules/system.nix`
- [x] 3.2 Add `e2e-rebuild-test` app entry to `nix/flake-modules/apps.nix`
- [x] 3.3 Add disk image to packages

## 4. Validation

- [x] 4.1 Build the disk image (`nix build .#redox-e2e-rebuild-test`)
- [x] 4.2 Run the test (`nix run .#e2e-rebuild-test`) and verify all FUNC_TEST lines pass
