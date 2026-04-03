## Why

With rustc and snix init panics fixed, 62 of 78 self-hosting tests pass. The remaining 16 failures are all snix builder/evaluator functional issues — the builds start but produce incorrect results or exit(1). These are the last blockers before the self-hosting image can compile real Rust programs via `snix build`.

The failures cluster into 4 root causes that need diagnosis and fix: directory output derivations, flake installable evaluation, multi-crate builds (cc-rs, workspaces, ripgrep), and `snix system rebuild --source`.

## What Changes

- Fix `snix build` for derivations producing directory trees (`$out/bin/`, `$out/version`)
- Fix `snix build .#hello` flake installable evaluation and building
- Fix `snix build` for derivations that invoke cargo (cc-rs, workspace, ripgrep) — likely sandbox allow-list or environment gaps
- Fix `snix system rebuild --source` for source-based system rebuilds
- Unblock ripgrep 33-crate build as the flagship end-to-end test

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
