## Why

The system management stack (rebuild, activate, services, environment.etc, activation scripts, generations, GC, boot components) has 607 unit tests covering individual functions but no end-to-end VM test that exercises the full `snix system rebuild` → activate → verify cycle. The rebuild-generations-test.nix predates the declarative services, environment.etc, and activation scripts changes — it tests hostname/generation mechanics but never verifies that config files appear on disk, activation scripts run, or service diffs are reported. A single integration test that boots a Redox VM, modifies configuration.nix, runs rebuild, and checks the live system state would prove the whole stack works together.

## What Changes

- New test profile `e2e-rebuild-test.nix` that boots a Redox VM and runs a multi-phase test:
  1. Verify initial system state (etc files from environment.etc, activation script markers, services running)
  2. Modify configuration.nix (change hostname, add an etc file, add an activation script, change a service)
  3. Run `snix system rebuild`
  4. Verify the live system reflects all changes (new hostname, new file on disk, marker from script, service diff reported)
  5. Run `snix system rebuild` again with no changes and verify it's a no-op
  6. Rollback and verify original state restored
- Wire the test into the flake as `nix run .#e2e-rebuild-test`
- New test script `21-e2e-rebuild.ion` with the guest-side test logic

## Capabilities

### New Capabilities
- `e2e-rebuild-validation`: End-to-end VM test covering rebuild + activate with config files, activation scripts, service changes, no-op detection, and rollback

### Modified Capabilities

## Impact

- New files: `nix/redox-system/profiles/e2e-rebuild-test.nix`, `nix/redox-system/test-scripts/21-e2e-rebuild.ion`
- Modified: `nix/flake-modules/system.nix` (add test system), `nix/flake-modules/apps.nix` (add app entry)
- No changes to snix-redox Rust code — this tests what's already built
