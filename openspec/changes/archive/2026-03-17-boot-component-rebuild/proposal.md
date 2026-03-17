## Why

`snix system rebuild` can detect hardware/driver changes via `has_boot_affecting_changes()` and route them to the bridge, but the detection is incomplete — init script additions/removals aren't considered boot-affecting even though they change the initfs. The bridge response installs boot component store paths, but rebuild doesn't compare boot paths between current and new manifests to show what changed. The current `merge_config` also doesn't update `manifest.boot` fields from the bridge response's boot component paths, so a local-only rebuild with hardware changes silently leaves stale boot paths in the manifest.

## What Changes

- Expand `has_boot_affecting_changes()` to also detect init script additions/removals (declared services that affect boot)
- Add boot path diffing to `print_changes()` — show when kernel/initfs/bootloader store paths change between current and new manifests
- Validate that `merge_config` propagates boot paths from bridge response manifests correctly
- Add unit tests covering all boot-affecting detection scenarios (hardware fields, init scripts, combined)
- Add unit tests for boot path diffing in change summary output

## Capabilities

### New Capabilities
- `boot-change-detection`: Complete boot-affecting change detection covering hardware fields and init script mutations, plus boot path diffing in rebuild output

### Modified Capabilities

## Impact

- `snix-redox/src/rebuild.rs` — `has_boot_affecting_changes()`, `print_changes()`, `merge_config()`, new tests
- `snix-redox/src/bridge.rs` — boot path propagation validation
- `openspec/specs/boot-component-rebuild/spec.md` — existing spec already covers the requirements
