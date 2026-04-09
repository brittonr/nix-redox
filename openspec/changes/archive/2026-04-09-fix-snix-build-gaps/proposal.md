## Why

After the sandbox rollback from per-path proxy to scheme-only (70b70d74),
the self-hosting baseline started at 65 pass, 13 fail out of 78 tests.
The 13 failures fell into test fixture/bundle issues (Ion builders for
derivations needing HOME, missing vendored crates, wrong Cargo vendor
paths) plus one snix-redox gap (`--no-sandbox` not threaded through
flake installables).

Current reproducible state (exact reruns on 2026-04-08, with attached evidence excerpts under `evidence/`):
- `snix-sandbox-test` passes **6/6** on detached worktree commit `c6a29e00`
- `self-hosting-test` completes at **77 pass, 1 fail** on detached worktree commit `c6a29e00`

So this change is still open, but the remaining scope is narrow. The sole blocker is
`snix-compile`.

## What Changes

- Fix test fixture/bundle issues for `cc-dep-build`, `rg-build`, `workspace-build`, and `snix-compile`
  (root causes: Ion builder scripts for derivations needing HOME, missing vendored crates,
  wrong Cargo vendor paths from `fetchCargoVendor` layout)
- Thread `--no-sandbox` flag through flake installables
- Fix `source-rebuild` test: seed manifest from live system, use full paths in builders
- Reorder `snix-compile` before `source-rebuild` (source-rebuild's activate mutates profile)
- Increase `snix-compile` timeout from 1500s to 2400s
- Validate ripgrep 33-crate build as the flagship end-to-end test

Remaining blocker: `snix-compile` still fails on the exact rerun. The attached evidence excerpt shows
`snix-compile-exit=1`, `FUNC_TEST:snix-compile:FAIL:exit or no binary at /bin/snix`, and
builder stderr ending at `Compiling proc-macro2 v1.0.106` / `Compiling quote v1.0.45`
before the derivation exits 101. That is now the evidence-backed baseline for the remaining work.

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
