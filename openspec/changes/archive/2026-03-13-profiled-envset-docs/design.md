## Context

Three items bundled into one change because they share a release boundary — all
should land before the next round of feature work.

**Profiled execution test (item 2):** The `rg-from-profile-works` test checks
`/nix/var/snix/profiles/default/bin/rg`, a filesystem symlink path. When
`profiled` is running as a scheme daemon, it serves file content through the
`profile:` scheme (`/scheme/profile/default/bin/rg`) but does NOT create
filesystem symlinks. The test SKIPs because the path doesn't exist.

The store path `/nix/store/{hash}-ripgrep/bin/rg` always exists on disk and is
executable. The test already discovers `rg_store_path` earlier in the suite.

**--env-set workaround (item 3):** `patch-cargo-env-set.py` adds `--env-set`
flags for `CARGO_PKG_*`, `OUT_DIR`, and `cargo:rustc-env` values. This works
around env vars not surviving `exec()` on Redox. `patch-rustc-execvpe.py` added
`execvpe()` which fixes basic vars but not `CARGO_PKG_*` in `env!()` macros
inside proc-macro crates (thiserror-impl, serde_derive). The napkin entry from
Mar 9 confirms 49/58 tests pass without `--env-set`, but 9 fail.

**README (item 6):** Last updated Feb 19. Missing: snix, scheme daemons, self-
hosting, build bridge, network cache, flake installables, redox-rebuild CLI.
Test counts say "~40" but actual: 461 host, 129 functional, 58 self-hosting.

## Goals / Non-Goals

**Goals:**
- Turn the skipped `rg-from-profile-works` into a passing test
- Determine whether `--env-set` can be removed now or needs to stay
- Update README to reflect current project state

**Non-Goals:**
- Making binaries executable via `profile:` scheme paths (future work)
- Fixing JOBS>1 parallel compilation
- Fixing the underlying DSO environ propagation bug (investigation only)
- Adding new features or packages

## Decisions

**Profiled test fix:** Change the test to execute rg via the store path
(`$rg_store_path/bin/rg --version`). Add a separate test that reads rg bytes
through the scheme path (`cat /scheme/store/{hash}/bin/rg | wc -c`) to verify
scheme-based file serving works. Keep a comment explaining why filesystem
profile paths don't exist when profiled is running.

**--env-set investigation approach:** Build a minimal reproducer — a crate with
`env!("CARGO_PKG_NAME")` — and test it with and without `--env-set`. If it
fails without, inspect the child process environ via `/proc/self/environ`
equivalent on Redox. Check whether the issue is in `execvpe()` itself or in
DSO relibc initialization clobbering the environ pointer. Document findings.
If the fix is non-trivial, keep `--env-set` and add a comment explaining
the permanent rationale.

**README structure:** Reorganize around the project's three layers:
1. Build system (Nix flakes → disk images)
2. OS configuration (module system, profiles)
3. Self-hosting (snix, scheme daemons, cargo on Redox)

## Risks / Trade-offs

- Removing `--env-set` prematurely would break proc-macro compilation (9 tests).
  Mitigation: investigate first, only remove if all 58 self-hosting tests pass.
- README rewrite is time-consuming but low-risk — no code changes.
- The profiled test fix is a workaround (testing store paths instead of profile
  paths). The real fix is making profiled create filesystem symlinks or supporting
  exec from scheme paths. Acceptable because the scheme daemon is still alpha.
