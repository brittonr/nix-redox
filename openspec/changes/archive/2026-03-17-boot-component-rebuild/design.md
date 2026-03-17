## Context

`rebuild.rs` already has `has_boot_affecting_changes()` checking hardware fields and `auto_rebuild()` routing to the bridge. The bridge protocol (`bridge.rs`) sends config to the host, gets back a full manifest with boot store paths, and `install_bridge_packages()` fetches boot components. The gap: init script changes aren't detected as boot-affecting, and `print_changes()` doesn't show boot path diffs.

The manifest (v3) stores `boot.kernel`, `boot.initfs`, `boot.bootloader` as store paths plus `services.declared` for service metadata. Init scripts get baked into the initfs at build time on the host, so any change to declared services that affects init scripts requires an initfs rebuild — same as driver changes.

## Goals / Non-Goals

**Goals:**
- `has_boot_affecting_changes()` detects init script mutations (new/removed services in `services` config field)
- `print_changes()` shows boot path diffs (kernel, initfs, bootloader) when they differ
- Unit tests for every detection path: each hardware field alone, services alone, combined, none

**Non-Goals:**
- Changing the bridge protocol — it already handles boot component delivery correctly
- Modifying the host-side build daemon — it already rebuilds everything when config changes
- Runtime init script reloading without reboot — that's a future change
- Detecting kernel config changes (kernel is currently a fixed derivation per flake rev)

## Decisions

**1. Init script detection via `services` field in RebuildConfig**

Add an optional `services` field to `RebuildConfig` that holds declared service names/types. When present, compare against current manifest's `services.declared` keys. Any difference (added/removed service names) is boot-affecting.

Alternative considered: tracking raw init script filenames. Rejected because manifest v3 already has `services.declared` with structured data — comparing service names is the right abstraction level.

**2. Boot path comparison in `print_changes()` uses `manifest.boot`**

Compare `Option<BootPaths>` between current and merged manifests. Show individual changes like `initfs: /nix/store/old-initfs → /nix/store/new-initfs`. When boot is `None` on either side (pre-v2 manifests), skip the comparison silently.

**3. No new `RebuildConfig` field for boot paths**

Boot paths come from the HOST via the bridge response manifest, not from configuration.nix. The `merge_config()` function doesn't touch `manifest.boot` — that's correct. Boot paths only change when the host rebuilds and returns new ones in the bridge response. The local rebuild path leaves boot paths unchanged (which is correct — you can't rebuild initfs locally).

## Risks / Trade-offs

- [Init script detection is coarse] Services field being `Some` triggers bridge even if the services match what's already in the manifest. Mitigation: compare against current manifest's declared services before flagging as boot-affecting.
- [Services config schema coupling] The `services` field in `RebuildConfig` needs to match what configuration.nix can express. For now it's just a list of service names — keep it simple, extend later if needed.
