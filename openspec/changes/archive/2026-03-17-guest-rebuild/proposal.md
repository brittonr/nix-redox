## Why

The `snix system rebuild` pipeline has all the parts — config evaluation, manifest merging, bridge routing, activation with semantic service diffs, generation creation, boot path tracking, reboot warnings. But the end-to-end story has three gaps that prevent the spec from being fully satisfied:

1. **No test coverage for service-level activation diffs** — the spec requires `+ serviceName (type)` / `- serviceName (type)` output during rebuild. The code does this (activate.rs lines 478-485), but no integration test verifies it.
2. **No test for "reboot recommended" message** — the spec requires this after boot-affecting changes. The code emits it (system.rs line 869), but no test captures it.
3. **No test for nonexistent package warning** — the spec says `--local` with a missing package should warn and NOT modify the manifest. The code warns (rebuild.rs resolve_packages_from_json), but no integration test covers the "manifest NOT modified" invariant.

These are test gaps, not implementation gaps. The Rust code is already correct. The change adds targeted unit tests that verify the spec scenarios not covered by the existing 58-test rebuild-generations suite.

## What Changes

- Add unit tests in rebuild.rs verifying the "nonexistent package with --local" scenario (warn + manifest unchanged)
- Add unit tests in activate.rs verifying semantic service diffs appear in activation plan display
- Add unit test in system.rs or activate.rs verifying reboot_recommended is set for boot path changes
- Verify the full spec coverage by mapping each scenario to existing or new tests

## Capabilities

### New Capabilities

### Modified Capabilities
- `guest-rebuild`: Add test coverage for service-level activation diffs, reboot-recommended message, and nonexistent package warning scenarios

## Impact

- `snix-redox/src/rebuild.rs` — new unit tests
- `snix-redox/src/activate.rs` — new unit tests for service diff display
