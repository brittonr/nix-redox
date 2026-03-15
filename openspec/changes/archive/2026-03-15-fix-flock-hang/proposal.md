## Why

Cargo on Redox intermittently hangs on `flock()` calls when acquiring `.package-cache` locks. The `flock()` syscall on Redox goes to the kernel's file scheme, which doesn't implement POSIX file locking — the call blocks forever. We currently work around this with `cargo-build-safe`, a bash wrapper that runs cargo in the background with a 90-second timeout, kills it on hang, deletes stale lock files, and retries once. This wrapper adds complexity to every cargo invocation in the self-hosting test suite (10+ call sites) and masks the root cause instead of fixing it.

The `fcntl` lock family (F_SETLK, F_SETLKW, F_OFD_SETLK) is already patched to no-op in relibc. The `flock()` syscall path is not — it still forwards to the kernel, where it hangs.

## What Changes

- Patch relibc's `flock()` implementation to return success immediately (no-op), matching the existing `fcntl` lock no-op pattern
- Remove the `cargo-build-safe` timeout wrapper from the self-hosting test profile
- Replace all `cargo-build-safe` invocations with direct `cargo build` calls
- Validate that all 62 self-hosting tests still pass without the wrapper

## Capabilities

### New Capabilities
- `flock-noop`: relibc `flock()` returns success immediately, preventing kernel hang on unsupported file locking

### Modified Capabilities

## Impact

- `nix/pkgs/system/patches/relibc/` — new patch file for flock no-op
- `nix/pkgs/system/relibc.nix` — add patch to patch list
- `nix/redox-system/profiles/self-hosting-test.nix` — remove cargo-build-safe wrapper creation and all references
- `AGENTS.md` — update active workarounds section, move flock hang to fixed
- `.agent/napkin.md` — update accordingly
