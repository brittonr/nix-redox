**Status: OPEN** — 77/78 pass. `snix-compile` remains failing (proc-macro linking abort). Tasks 6.3 and 7.4 are incomplete.

## 1. Diagnose all 16 failures with verbose output

- [x] 1.1 Run the test suite with `--verbose` and capture full stderr for each failing test into a log file
- [x] 1.2 Extract the snix error message for each failure (the exit=1 stderr, not just the FUNC_TEST line)
- [x] 1.3 Classify each failure by root cause: directory-output, flake-eval, sandbox-gap, rebuild-bug, or test-script-bug

## 2. Fix directory output derivations (`snix-build-dir`)

- [x] 2.1 Read the `snix-build-dir` stderr from the verbose log — identify whether it's an output verification issue, NAR hash issue, or builder failure
- [x] 2.2 Read `snix-redox/src/local_build.rs` output verification code — check how it handles `$out` as a directory vs a file
- [x] 2.3 Implement the fix in `local_build.rs`
- [x] 2.4 Rebuild and verify `snix-build-dir` passes

## 3. Fix flake installable builds (`flake-build`, `flake-cached`, `flake-registered`)

- [x] 3.1 Read the `flake-build` stderr from the verbose log — identify whether it's eval failure, input resolution, or build failure
- [x] 3.2 Read `snix-redox/src/flake.rs` — trace the flake evaluation path for `/usr/src/test-flake#hello`
- [x] 3.3 Check the test flake contents on the disk image (`/usr/src/test-flake/flake.nix`, `flake.lock`)
- [x] 3.4 Implement the fix in `flake.rs` or the test flake definition
- [x] 3.5 Rebuild and verify `flake-build` passes (which should cascade to `flake-cached` and `flake-registered`)

## 4. Fix sandbox gaps for cargo builds (`snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build`)

- [x] 4.1 Read the `snix-build-cargo` and `cc-dep-build` stderr — identify which file access the sandbox blocked or which env var is missing
- [x] 4.2 Read `snix-redox/src/build_proxy/allow_list.rs` — check what paths are currently allowed for builders
- [x] 4.3 Read `snix-redox/src/local_build.rs` — check what environment variables are set for the builder process
- [x] 4.4 Compare the sandbox environment with what a direct `cargo build` gets (the working cargo tests from the rustc fix prove cargo itself works)
- [x] 4.5 Fix cargo-build test failures (root cause: test fixture/bundle issues, not sandbox allow-list)
- [x] 4.6 Thread `--no-sandbox` flag through flake installables (`flake.rs` → `build_needed_with_options`)
- [x] 4.7 Rebuild and verify `snix-build-cargo` passes
- [x] 4.8 Verify `cc-dep-build` and `workspace-build` pass
- [x] 4.9 Verify `rg-build` passes (and downstream `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`)

Note on sandbox-core vs fixture changes:

Sandbox-core changes (snix-redox/src/) that unblocked cargo builds were done
in a prior change (stabilize-self-hosting-baseline). Three /dev/* issues fixed:
1. /dev/null not in allow list (daf86cc4 — `allow_list.rs`)
2. /dev/null needs read-WRITE not read-only (daf86cc4 — `handler.rs`)
3. /dev/* opens via File::open() deadlocks initnsmgr (6bb97e16 — `lifecycle.rs`, `handler.rs`)

This change (fix-snix-build-gaps) fixed the *remaining* cargo-build failures, whose
root causes were in test fixtures/bundles, NOT in snix-redox sandbox code:
- `cc-dep-build`: Ion rejects `let HOME = ...` → switched builder to bash; `cc` 1.2.21 needs
  vendored `shlex` → added to `cc-dep-test-bundle.nix`
- `rg-build`: `build-ripgrep.nix`/`.sh` used Ion even though builder needs HOME → switched to
  bash; `ripgrep-source-bundle.nix` pointed Cargo at `vendor/` while `fetchCargoVendor` lays
  crates out under `vendor/source-registry-0/` → fixed path
- `workspace-build`: `snix-sandbox-test` checked for `$out/bin/workspace-test` but derivation
  installs `$out/bin/mybin` → fixed test expectation
- `snix-compile`: `build-snix.nix`/`.sh` needed bash builder + Cargo pointed at
  `vendor/source-registry-0` and `vendor/source-git-0`

The only snix-redox source change in this change was threading `--no-sandbox` through
flake installables (`main.rs` → `flake.rs` → `build_needed_with_options`).

Focused `snix-sandbox-test` rerun on 2026-04-07 passes (6/6):
- `snix-simple`, `snix-build-cargo`, `flake-build`, `cc-dep-build`, `workspace-build`, `rg-build`

## 5. Fix source-based rebuild (`source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg`)

- [x] 5.1 Read the `source-rebuild` stderr from the verbose log
- [x] 5.2 Read `snix-redox/src/rebuild.rs` `rebuild_from_source()` — trace the failure path
- [x] 5.3 Implement the fix (likely depends on fixes from tasks 2-4 since rebuild invokes snix build internally)
- [x] 5.4 Rebuild and verify `source-rebuild` passes (cascades to `source-rebuild-gen` and `source-rebuild-pkg`)

## 6. Fix snix self-compile (`snix-compile`)

- [x] 6.1 Read the `snix-compile` stderr — determine if it's a timeout, sandbox issue, or build failure
- [x] 6.2 If sandbox issue: apply same fixes as task 4. If timeout: increase test timeout or optimize build.
- [ ] 6.3 Rebuild and verify `snix-compile` passes

Note: snix-compile now proceeds past sandbox init. With 2400s timeout and test reorder
(snix-compile before source-rebuild), the build reaches proc-macro build-script
compilation but linking aborts with `failed to initiate panic, error 0` (unwind stubs).

## 7. End-to-end validation (post-rollback baseline: 2026-04-07)

Full baseline after test reorder (all 78 tests report):
  77 pass, 1 fail (out of 78 tests)

Current failures after the 2026-04-07 full rerun (verified in task 131, 2400s timeout):
- snix-compile: FAIL — self-build reaches proc-macro build-script compilation (proc-macro2, quote), then linking via `/nix/system/profile/bin/cc` aborts with `failed to initiate panic, error 0` / exit 134 (unwind stubs). Derivation exits 101 before producing `$out/bin/snix`. Fix applied: reordered snix-compile before source-rebuild (source-rebuild's activate() drops ld.lld from profile) and increased timeout from 1500s to 2400s.

Verification evidence (summaries from pueue task logs, captured during 2026-04-07 session):

1. **Focused sandbox rerun** (6 tests, commit range 70b70d74..c6a29e00):
   Tests: `snix-simple`, `snix-build-cargo`, `flake-build`, `cc-dep-build`, `workspace-build`, `rg-build`.
   Result: **Passed: 6, Failed: 0**. All cargo-build derivations succeed under scheme-only sandbox.

2. **Full suite after ripgrep fixes** (78 tests):
   Newly passing: `snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build`, `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`.
   Result: **Passed: 71, Failed: 7**. Remaining failures: flake-*, source-rebuild-*, snix-compile.

3. **Full suite after source-rebuild fixes** (78 tests):
   Newly passing: `flake-build`, `flake-cached`, `flake-registered`, `source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg`, `source-rebuild-dry`.
   Result: **Passed: 74, Failed: 4**. Remaining failures: snix-compile + 3 dependent tests.

4. **Full suite after snix-compile fixture fixes** (78 tests, pre-reorder):
   Newly passing: `snix-binary-exists`, `snix-binary-runs`, `snix-eval-works`.
   Result: **Passed: 77, Failed: 1**. `snix-compile` failed due to lld-wrapper ENOENT caused by source-rebuild's `activate()` mutating the live profile mid-suite.

5. **Current baseline** (78 tests, post-reorder + 2400s timeout, commit c6a29e00):
   All 78 tests report results. `snix-compile` runs before `source-rebuild` (no profile mutation).
   `snix-compile` FAIL: build reaches proc-macro build-script linking, then `cc` aborts with `failed to initiate panic, error 0` / exit 134. Derivation exits 101.
   Result: **Passed: 77, Failed: 1**. Total time: 2241s.

- [x] 7.1 Fix cc-dep-build: diagnose cc-rs exit=1 under scheme-only sandbox
- [x] 7.2 Fix rg-build: diagnose why binary not at output path (exit=0 but no binary)
- [x] 7.3 Fix source-rebuild: diagnose exit=1 from snix system rebuild --source
- [ ] 7.4 Fix snix-compile: diagnose why binary not at expected output path
- [x] 7.5 Document remaining failures and root causes
- [x] 7.6 Update AGENTS.md with new snix builder knowledge
