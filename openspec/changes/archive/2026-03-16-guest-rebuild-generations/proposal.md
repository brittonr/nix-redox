## Why

The pieces for declarative system management exist — `snix system rebuild` evaluates `configuration.nix`, `snix system switch` manages generations, `snix system rollback` reverts — but none of these paths have been tested end-to-end inside a running VM. The bridge-rebuild-test exercises the host-delegated rebuild path (`--bridge`), but the local rebuild path (guest evaluates config, resolves packages from its own cache, activates) has zero VM coverage. Generations are created by `switch()` but never tested: no test boots a system, makes a change, verifies the generation was saved, and rolls back.

Without test coverage, these code paths rot. Worse, users who boot the graphical or development image and try `snix system rebuild` or `snix system rollback` hit untested code running against real Redox I/O constraints (Ion shell, relibc, scheme daemons).

## What Changes

- **New VM test profile** (`rebuild-generations-test.nix`) that boots a Redox image and runs an automated test suite exercising the full lifecycle: read current config → edit configuration.nix → rebuild → verify activation → list generations → rollback → verify rollback state.
- **New `nix run .#rebuild-generations-test`** app wired into the flake.
- **Bug fixes** in `snix system rebuild`, `switch`, `rollback`, `generations`, and `activate` discovered by the tests. The code exists but has never run against a real manifest on a real Redox filesystem — expect edge cases around path resolution, file permissions, and scheme daemon interactions.
- **Existing test harness integration** — the new test uses the same `FUNC_TEST:name:PASS/FAIL` protocol as functional-test and self-hosting-test, with serial output parsing.

## Capabilities

### New Capabilities
- `guest-rebuild`: End-to-end test coverage for `snix system rebuild` (local, non-bridge) — evaluating configuration.nix, resolving packages, merging manifests, and activating on a live system.
- `generation-management`: End-to-end test coverage for `snix system generations`, `snix system switch`, and `snix system rollback` — verifying generation creation, listing, and rollback produce correct system state.

### Modified Capabilities

## Impact

- **snix-redox/src/rebuild.rs** — likely fixes for path handling, missing cache index, or eval failures on real Redox.
- **snix-redox/src/system.rs** — `switch()`, `rollback()`, `generations()` may need fixes for Redox filesystem semantics (e.g., mkdir_p, file permissions, canonicalize returning `file:/path`).
- **snix-redox/src/activate.rs** — profile swap and config file updates may hit edge cases with scheme daemons running (profiled, stored).
- **nix/redox-system/profiles/** — new `rebuild-generations-test.nix` profile.
- **nix/flake-modules/apps.nix** — new test runner app.
- **nix/redox-system/modules/build/** — may need to ensure the test profile gets a usable configuration.nix and populated binary cache on disk.
