## Why

The `snix channel` and `snix system upgrade` subsystems exist (324 LOC in channel.rs, upgrade flow in system.rs) but have zero VM-level testing. Every other major snix subsystem — install, rebuild, generations, GC, activation — has a dedicated VM test profile that proves it works end-to-end on real Redox hardware. Channels are the primary mechanism for remote system updates, and an untested upgrade path is a liability.

## What Changes

- New VM test profile (`channel-update-test.nix`) that boots Redox with networking, registers a channel pointing to the host HTTP cache, fetches the manifest, and runs `snix system upgrade` to completion.
- New flake app entry (`channel-update-test`) wired into the test runner infrastructure alongside the existing network-install-test.
- Test Ion script exercising: `snix channel add`, `snix channel list`, `snix channel update`, `snix system upgrade --yes`, and post-upgrade verification (new generation created, manifest updated).

## Capabilities

### New Capabilities
- `channel-update-validation`: VM test profile and Ion test script proving the channel add → update → upgrade → generation pipeline works end-to-end over HTTP.

### Modified Capabilities
_(none — this adds a test, not new runtime behavior)_

## Impact

- `nix/redox-system/profiles/channel-update-test.nix` — new file
- `nix/flake-modules/apps.nix` — new app entry
- `nix/pkgs/infrastructure/default.nix` — new test runner wiring (if needed)
- No changes to snix-redox Rust code unless tests expose bugs
