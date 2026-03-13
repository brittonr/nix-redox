## Why

The `--env-set` cargo patch was added as defense-in-depth when DSO environ propagation was broken — `Command::env()` values weren't reaching `env!()` macros in rustc because dynamically-linked libraries inherited NULL environ pointers. Two relibc patches (`patch-relibc-environ-dso-init` and `patch-relibc-dso-environ`) fixed the root cause, and the self-hosting test suite has since run 62/62 PASS at JOBS=2 including builds that exercise `env!()`, `option_env!()`, and build-script env propagation (snix 193 crates, ripgrep 33 crates, proc-macro crates). The `--env-set` patch duplicates every CARGO_PKG_* and build-script env var as a CLI flag — extra process argument overhead, extra patch maintenance, and a redundant code path that masks regressions in the real environ fix.

## What Changes

- **Remove `patch-cargo-env-set.patch`** from the cargo build and delete the patch file. This removes the `--env-set` CLI flag injection for CARGO_PKG_*, OUT_DIR, and build-script env vars.
- **Update self-hosting tests** that reference `--env-set` in comments or test logic. The env-propagation-simple test explicitly checks "`env!() works via --env-set`" in its failure path — that message becomes wrong once the patch is gone.
- **Update napkin and AGENTS.md** to move `--env-set` from "Active Workarounds" to "Stale Claims (verified removed)".

## Capabilities

### New Capabilities
- `env-set-removal`: Removal of the `--env-set` cargo patch and validation that DSO environ propagation handles all env!() use cases without it.

### Modified Capabilities

## Impact

- `nix/pkgs/userspace/patches/patch-cargo-env-set.patch` — deleted
- `nix/pkgs/userspace/rustc-redox.nix` — patch list updated (one fewer patch)
- `nix/redox-system/profiles/self-hosting-test.nix` — comments referencing `--env-set` updated
- `.agent/napkin.md` — workaround section updated
- `AGENTS.md` — `--env-set` entry updated
