## Context

Generations work at runtime: `snix system switch` saves the current manifest, rebuilds the profile with the new package set, writes derived config files (`/etc/hostname`, `/etc/timezone`, `/etc/net/dns`), and records a generation. `snix system rollback --generation N` reverses this. Both operations complete in milliseconds — 43 tests pass across 8 generations in 2 seconds.

The gap: after a reboot, the system always boots with whatever manifest was active when it shut down. There's no way to select a different generation at boot time. If a configuration change breaks the system badly enough that it can't reach a shell, the only recovery is rebuilding the disk image.

The bootloader (`boot/kernel`, `boot/initfs`) is loaded from RedoxFS by the UEFI bootloader which hardcodes `load_to_memory(fs, "boot", "kernel")`. All generations share the same kernel and initfs. The boot sequence is: bootloader → kernel → initfs init scripts (`00_runtime` through `50_rootfs` mount root, `90_exit_initfs` enters userspace).

## Goals / Non-Goals

**Goals:**
- Boot into any stored generation without rebuilding the disk image
- Persist the default generation across reboots
- Fall back safely if the selected generation can't be activated
- `snix system boot N` sets the next-boot generation without changing the live system
- Integration test proving the boot generation selector works end-to-end

**Non-Goals:**
- Bootloader UI modification (Phase 3 — future change)
- Per-generation kernel/initfs storage (Phase 2 — future change)
- Recovery from kernel or initfs failures (requires bootloader-level selection)
- Interactive generation menu at boot time (future — could add keypress detection in init)

## Decisions

### 1. Activate between root mount and userspace entry

Insert `85_generation_select` between `50_rootfs` (root filesystem mounted, `/etc/` accessible) and `90_exit_initfs` (PATH set, getty/shell started). This is the only correct position: we need the root filesystem to read generation manifests, and we need to finish before the profile PATH is used.

The init script runs `/bin/snix system activate-boot` which reads the default generation marker, loads the stored manifest, and runs `activate()`. This is the same code path as `rollback` minus the generation metadata bookkeeping.

*Alternative: Activate in `90_exit_initfs` itself.* Rejected — `90_exit_initfs` sets PATH to include `/nix/system/profile/bin` and starts services. The profile must already reflect the correct generation before that happens.

### 2. `/boot/default-generation` marker file

A plain text file containing a generation ID (e.g., `5`). Written by `switch()`, `rollback()`, and the new `boot` subcommand. Read by the `85_generation_select` init script.

Located in `/boot/` rather than `/etc/` because it's boot infrastructure. The bootloader already reads from `/boot/`. Future Phase 3 (bootloader menu) would also read from here.

*Alternative: Kernel environment variable.* The bootloader's env editor could set `GENERATION=N`, but this doesn't persist across reboots without modifying the bootloader's default env. The marker file persists naturally on the filesystem.

### 3. `activate-boot` subcommand (not reusing `rollback`)

`rollback` creates a new generation, bumps the ID, and updates the description. Boot activation should NOT do this — it's restoring an already-recorded state, not creating a new one. A separate `activate-boot` subcommand loads a generation's manifest and calls `activate()` without creating a new generation entry.

*Alternative: `rollback --no-new-generation`.* Adds a flag to an already complex command. A dedicated subcommand is clearer about its purpose and easier to call from init scripts.

### 4. Fallback: boot current manifest on failure

If `activate-boot` fails (corrupt manifest, missing store paths, permission errors), the system continues booting with whatever manifest is currently on disk. This is always a valid state — it's what the last successful `switch` or `rollback` left behind. The failure is logged to serial via `debug:`.

*Alternative: Halt and display an error.* Too aggressive — a partially-correct boot is better than no boot. The user can fix things from the shell.

### 5. `snix system boot N` sets next-boot without live activation

Writes `/boot/default-generation` to N but does NOT call `activate()`. The current running system is unchanged. On next reboot, `85_generation_select` activates generation N. This mirrors NixOS's `nixos-rebuild boot` (vs `nixos-rebuild switch`).

Running `snix system boot` without an argument shows the current default.

## Risks / Trade-offs

- **[Timing in init sequence]** The `85_generation_select` script runs after root mount but before `ptyd` and other rootfs services. `snix` is a statically linked binary in `/bin/` (boot-essential), so it doesn't need services to be running. Profile rebuild is pure filesystem operations (symlinks + file writes). → Low risk.

- **[Init script environment]** Init scripts run with PATH set to `/scheme/initfs/bin`. The `snix` binary must be at `/bin/snix` on the root filesystem, which is accessible after `50_rootfs` mounts it. The init script uses absolute path `/bin/snix`. → Handled.

- **[Corrupt generation manifest]** If `/etc/redox-system/generations/N/manifest.json` is corrupt or has dangling store path references, `activate-boot` will fail. → Falls back to current manifest. Could add a `--verify` flag that checks store path existence before activating.

- **[Default marker out of sync]** If generations are garbage collected but `/boot/default-generation` still references a deleted generation, boot activation fails. → Fallback handles this. GC should update the marker.
