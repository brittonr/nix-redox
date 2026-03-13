## Context

The `--env-set` cargo patch injects every CARGO_PKG_* variable and build-script output env var as a `rustc --env-set KEY=VALUE` CLI argument, duplicating what `Command::env()` already does. This was necessary when DSO environ propagation was broken — `librustc_driver.so` couldn't see process env vars set by cargo because each DSO got a NULL environ pointer from ld_so.

Two relibc patches fixed the root cause:
1. `patch-relibc-environ-dso-init` — after `relibc_start_v1` sets environ from kernel envp, broadcasts it to `__relibc_init_environ` so DSOs see it via GLOB_DAT.
2. `patch-relibc-dso-environ` — `getenv()` self-initializes from `__relibc_init_environ` when environ is NULL (lazy init on first call in a DSO).

The self-hosting test suite validated this at 62/62 PASS with JOBS=2, including `env!("CARGO_PKG_NAME")`, `option_env!("LD_LIBRARY_PATH")`, proc-macro crates, build scripts, and 193-crate workspace builds.

## Goals / Non-Goals

**Goals:**
- Remove `patch-cargo-env-set.patch` and its reference in `rustc-redox.nix`
- Update test comments that reference `--env-set` as the mechanism for env!() working
- Update documentation (napkin, AGENTS.md) to reflect the removal
- Validate 62/62 self-hosting tests still pass without the patch

**Non-Goals:**
- Changing the DSO environ patches (those stay)
- Removing `cargo-build-safe` timeout wrapper (separate concern, still needed for flock)
- Modifying the env-propagation test logic itself (the tests check real environ, they should keep doing that)

## Decisions

**Remove the patch entirely rather than gating it behind a flag.**
The patch has a single purpose — duplicate env vars through a second channel. With the root cause fixed and 62/62 tests validating the fix under heavy load (JOBS=2, fork storms, proc-macros), there's no value in keeping a disabled copy. The `.patch` file stays in git history if ever needed again.

**Keep env-propagation tests unchanged except for comments.**
The env-propagation-simple and env-propagation-heavy tests check actual environ propagation via `option_env!("LD_LIBRARY_PATH")` — they test the DSO environ fix, not `--env-set`. Only the failure-path messages and inline comments reference `--env-set` and need updating.

**Build validation: full self-hosting-test run.**
No shortcut. The change removes a fallback path, so the full 62-test suite must pass to confirm nothing depended on `--env-set` as the primary channel.

## Risks / Trade-offs

**[Risk] A crate depends on `--env-set` for an env var not covered by the DSO fix** → Low. The DSO fix handles all env vars (full environ pointer), not specific ones. The `--env-set` patch only covered CARGO_PKG_*, OUT_DIR, and build-script vars — a subset of what `Command::env()` sets.

**[Risk] Future relibc regression breaks DSO environ again** → The env-propagation-simple and env-propagation-heavy tests catch this explicitly. They test `option_env!("LD_LIBRARY_PATH")` which is NOT a CARGO_PKG_* var — it can only work through real environ propagation.

**[Trade-off] Losing a redundant safety net** → Accepted. The redundancy masked potential regressions in the DSO fix rather than catching them. With the patch gone, any DSO environ regression shows up immediately in tests.
