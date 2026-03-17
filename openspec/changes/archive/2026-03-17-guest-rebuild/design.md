## Context

The existing `snix system rebuild` pipeline is functionally complete:
- `rebuild.rs`: config eval → merge → package resolution → `system::switch()`
- `bridge.rs`: bridge protocol for package/boot changes
- `activate.rs`: semantic service diffs (`+ name (type)` / `- name (type)`), boot component updates, reboot_recommended flag
- `system.rs`: generation creation, manifest persistence, reboot warning display

The rebuild-generations-test profile has 58 integration tests covering show-config, dry-run, hostname rebuild, rollback, generation switching, GC, boot paths, and package addition. Three spec scenarios lack test coverage.

## Goals / Non-Goals

**Goals:**
- Unit tests for: nonexistent package warning without manifest modification
- Unit tests for: activation plan contains semantic service diff lines
- Unit tests for: reboot_recommended set when boot paths change
- Spec coverage map showing each scenario → test name

**Non-Goals:**
- New integration test profile (the existing 58-test suite + new unit tests are sufficient)
- Changing any runtime behavior (the code is already correct)
- Bridge rebuild integration testing (separate concern, needs live VM)

## Decisions

**1. Unit tests over integration tests for the remaining gaps**

The missing scenarios are about output formatting and flag values — unit tests are the right level. Integration tests for "does the warning print" are fragile (depend on exact output parsing through Ion shell). Unit tests directly assert on function return values and data structures.

**2. Test nonexistent package by calling merge_config with unresolved packages**

`resolve_packages_from_json` already returns packages with empty `store_path` for unknowns. The merge function preserves boot-essential packages and skips empty-path packages. Test that the manifest's package list is unchanged when all resolved packages have empty paths.

**3. Test service diffs via ActivationPlan construction**

`ActivationPlan::compute()` takes old and new manifests and produces `services_added`, `services_removed`. Test that these contain the expected `ServiceChange` entries with correct names and types.

## Risks / Trade-offs

- [Unit tests don't catch integration bugs] The activation plan display goes through `println!` which is hard to capture. We test the data structure, not the formatted output. The formatted output is already visually verified in integration tests.
