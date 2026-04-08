## Why

After the sandbox rollback from per-path proxy to scheme-only (70b70d74),
the self-hosting baseline was re-established on 2026-04-07:
65 pass, 13 fail out of 78 tests (all tests report after test reorder).

Most of the original 16 failures from the proxy era are now fixed. The
remaining gaps are: cc-dep-build (cc-rs exits non-zero under sandbox),
snix-compile timeout (168 crates exceed 1800s budget), and tests blocked
behind the snix-compile timeout that never got a chance to run.

## What Changes

- Fix test fixture/bundle issues for `cc-dep-build`, `rg-build`, `workspace-build`, and `snix-compile`
  (root causes: Ion builder scripts for derivations needing HOME, missing vendored crates,
  wrong Cargo vendor paths from `fetchCargoVendor` layout)
- Thread `--no-sandbox` flag through flake installables
- Fix `source-rebuild` test: seed manifest from live system, use full paths in builders
- Reorder `snix-compile` before `source-rebuild` (source-rebuild's activate mutates profile)
- Increase `snix-compile` timeout from 1500s to 2400s
- Validate ripgrep 33-crate build as the flagship end-to-end test

Remaining blocker: `snix-compile` proc-macro build-script linking aborts with unwind stubs
(`failed to initiate panic, error 0`). This is a platform-level issue, not a fixture bug.

## Capabilities

### New Capabilities

### Modified Capabilities
- `nix-derivation-builds`: Directory output derivations, flake installables, cargo-inside-sandbox builds, and source rebuild must succeed

## Impact

- `snix-redox/src/flake.rs` — `--no-sandbox` threading, GitLab tarball URL fix
- `snix-redox/src/main.rs` — pass `no_sandbox` to `build_flake_installable`
- `snix-redox/src/local_build.rs` — minor cleanup (unused variable rename)
- `snix-redox/src/sandbox.rs` — doc/comment updates (no behavioral change)
- `nix/pkgs/infrastructure/*.nix` — test fixture fixes (bash builders, vendored crates, Cargo paths)
- `nix/pkgs/infrastructure/*.sh` — builder script rewrites (Ion → bash for HOME-needing builds)
- `nix/redox-system/profiles/self-hosting-test.nix` — test reorder, timeout increase, expectation fixes
- `nix/redox-system/profiles/snix-sandbox-test.nix` — workspace-build expectation fix

Note: sandbox-core changes (allow_list.rs, handler.rs, lifecycle.rs) were in the
prior change (stabilize-self-hosting-baseline), not this one.
