## Why

After the sandbox rollback from per-path proxy to scheme-only (70b70d74),
the self-hosting baseline was re-established on 2026-04-07:
65 pass, 13 fail out of 78 tests (all tests report after test reorder).

Most of the original 16 failures from the proxy era are now fixed. The
remaining gaps are: cc-dep-build (cc-rs exits non-zero under sandbox),
snix-compile timeout (168 crates exceed 1800s budget), and tests blocked
behind the snix-compile timeout that never got a chance to run.

## What Changes

- Fix `cc-dep-build`: diagnose why cc-rs build script fails under scheme-only sandbox
- Fix `snix-compile` timeout: increase test budget or restructure to skip in main suite
- Unblock remaining tests (source-rebuild, rg-build, parallel, e2e-rebuild) that are
  currently blocked behind the snix-compile timeout
- Validate ripgrep 33-crate build as the flagship end-to-end test

## Capabilities

### New Capabilities

### Modified Capabilities
- `nix-derivation-builds`: Directory output derivations, flake installables, cargo-inside-sandbox builds, and source rebuild must succeed

## Impact

- `snix-redox/src/local_build.rs` — build output verification, directory output handling
- `snix-redox/src/flake.rs` — flake lock resolution, input fetching on Redox
- `snix-redox/src/build_proxy/` — sandbox allow-list gaps for cc-rs, lld, cargo environment
- `snix-redox/src/sandbox.rs` — namespace setup for complex builds
- `snix-redox/src/rebuild.rs` — source-based rebuild flow
- `nix/redox-system/profiles/self-hosting-test.nix` — test script adjustments if test expectations are wrong
