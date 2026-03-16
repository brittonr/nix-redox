## Why

System generation switching currently only works at runtime via `snix system rollback`. If a bad configuration or package change renders the system unresponsive after reboot, there's no way to recover without rebuilding the disk image. NixOS solves this with bootloader-level generation selection. Redox needs the same property: boot into any previous generation to recover from broken changes.

## What Changes

- Add an `85_generation_select` init script that activates a selected generation between root mount and userspace entry
- `snix system switch` and `snix system rollback` write a `/etc/redox-system/boot-default` marker so the chosen generation persists across reboots
- New `snix system boot` subcommand: set which generation to boot next without activating it live
- Generation activation at boot time: read the marker, load the stored manifest, rebuild the profile, write config files — all before getty/shell starts
- Fallback behavior: if the selected generation's activation fails, boot with the current on-disk manifest and log a warning

## Capabilities

### New Capabilities
- `boot-generation-select`: Boot-time generation activation — reading a default-generation marker, activating the selected generation's manifest during init, and falling back safely on failure

### Modified Capabilities
- `generation-management`: Extend switch/rollback to write a boot default marker, add `snix system boot` subcommand for setting next-boot generation without live activation

## Impact

- `snix-redox/src/system.rs`: switch() and rollback() write `/etc/redox-system/boot-default`
- `snix-redox/src/activate.rs`: extract activation into a standalone entry point callable from init
- `nix/redox-system/modules/build/init-scripts.nix`: new `85_generation_select` init script
- `nix/redox-system/profiles/`: new test profile for boot generation selection
- `nix/pkgs/infrastructure/`: new integration test runner
- Init script runs between `50_rootfs` (root mounted) and `90_exit_initfs` (userspace entry)
