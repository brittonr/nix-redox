## Why

The Redox init binary supports a debug mode via the `INIT_LOG_LEVEL` environment variable — when set to `DEBUG` or `TRACE`, it logs each command, service spawn, and target reached. There's also `INIT_SKIP` for skipping specific commands during boot. Currently the only way to set these is the bootloader's interactive env editor (press `e` at the resolution screen), which requires manual keypresses at every boot. There's no declarative way to enable init debugging.

## What Changes

- Add `boot.initDebug` boolean option (default `false`). When true, causes `INIT_LOG_LEVEL=DEBUG` to be present in init's process environment.
- Add `boot.initSkip` list-of-strings option (default `[]`). Causes `INIT_SKIP=cmd1,cmd2,...` to be present in init's process environment, skipping named commands during boot.
- Both env vars are injected via the bootstrap binary, which reads an optional `etc/init.env` file from the initfs before exec'ing init. This follows the same pattern as bootstrap's existing hardcoded `RUST_BACKTRACE=1`.
- The init binary itself is unmodified — it already reads these env vars.

## Capabilities

### New Capabilities
- `init-debug-config`: Nix module options to control init's debug logging and command skipping, with env var injection through a bootstrap patch and initfs env file.

### Modified Capabilities

None.

## Impact

- `nix/redox-system/modules/boot.nix` — new option declarations
- `nix/redox-system/modules/build/config.nix` — forward new options to cfg
- `nix/redox-system/modules/build/initfs.nix` — conditionally write `etc/init.env` into initfs
- `nix/patches/patch-bootstrap-init-env.py` — new patch for `base/bootstrap/src/exec.rs` to read the env file
- Base package build — wire in the new bootstrap patch
- No changes to the init binary or bootloader
