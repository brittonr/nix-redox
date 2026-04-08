**Status: OPEN** — exact reruns of detached worktree commit `c6a29e00` on 2026-04-08 re-verify the focused sandbox subset (**6/6 pass**) and the full self-hosting suite (**77 pass, 1 fail, 78 total**). The sole remaining failure is `snix-compile`, so tasks 6.3 and 7.4 stay incomplete.

Evidence note: attached rerun evidence excerpts now live under `openspec/changes/fix-snix-build-gaps/evidence/`.
Start with `evidence/README.md`, then inspect the committed excerpts directly.

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

## 4. Resolve cargo-build failures under the scheme-only sandbox (`snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build`)

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

Direct re-verification for tasks 4.7-4.9:
- `evidence/c6a29e00-snix-sandbox-test-2026-04-08.excerpt.txt` contains PASS lines for `snix-simple`, `snix-build-cargo`, `flake-build`, `cc-dep-build`, `workspace-build`, and `rg-build`, plus the final `Passed:  6` / `Failed:  0` / `Total:   6` summary.
- `evidence/c6a29e00-self-hosting-test-2026-04-08.excerpt.txt` contains the downstream ripgrep PASS lines for `rg-version`, `rg-search`, `rg-store-path`, and `rg-binary-size`, as well as `parallel-jobs2:PASS`.

## 5. Fix source-based rebuild (`source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg`)

Direct re-verification for task 5.4:
- `evidence/c6a29e00-self-hosting-test-2026-04-08.excerpt.txt` contains `FUNC_TEST:source-rebuild:PASS`, `FUNC_TEST:source-rebuild-gen:PASS`, `FUNC_TEST:source-rebuild-pkg:PASS`, and `FUNC_TEST:source-rebuild-dry:PASS`.

- [x] 5.1 Read the `source-rebuild` stderr from the verbose log
- [x] 5.2 Read `snix-redox/src/rebuild.rs` `rebuild_from_source()` — trace the failure path
- [x] 5.3 Implement the fix (likely depends on fixes from tasks 2-4 since rebuild invokes snix build internally)
- [x] 5.4 Rebuild and verify `source-rebuild` passes (cascades to `source-rebuild-gen` and `source-rebuild-pkg`)

## 6. Fix snix self-compile (`snix-compile`)

- [x] 6.1 Read the `snix-compile` stderr — determine if it's a timeout, sandbox issue, or build failure
- [x] 6.2 If sandbox issue: apply same fixes as task 4. If timeout: increase test timeout or optimize build.
- [ ] 6.3 Rebuild and verify `snix-compile` passes

Note: the exact rerun attached as `evidence/c6a29e00-self-hosting-test-2026-04-08.excerpt.txt`
reproduces a full-suite `77/1` result. `snix-compile` still fails: the attached excerpt shows
`snix-compile-exit=1`, `FUNC_TEST:snix-compile:FAIL:exit or no binary at /bin/snix`,
and builder stderr ending at `Compiling proc-macro2 v1.0.106` / `Compiling quote v1.0.45`
before the derivation exits 101.

## 7. End-to-end validation (post-rollback baseline)

Current reproducible baseline after exact reruns on 2026-04-08:
- focused `snix-sandbox-test`: **6 pass, 0 fail** (all 6 tests report)
- full `self-hosting-test`: **77 pass, 1 fail, 78 total**

Current remaining blocker after the exact reruns:
- `snix-compile`: the full-suite rerun completes, but `snix build --file` exits 1 / derivation exit 101 and no `/bin/snix` is produced for the self-compile test.

Verification evidence (direct reruns captured on 2026-04-08):

1. **Post-change focused rerun against detached worktree commit `c6a29e00`**
   Command: `cd /tmp/redox-c6a29e00 && nix run .#snix-sandbox-test -- --verbose`
   Attached excerpt: `evidence/c6a29e00-snix-sandbox-test-2026-04-08.excerpt.txt`
   Result summary from excerpt: `Passed:  6`, `Failed:  0`, `Total:   6`, `FUNCTIONAL TEST PASSED`

2. **Post-change full rerun against detached worktree commit `c6a29e00`**
   Command: `cd /tmp/redox-c6a29e00 && nix run .#self-hosting-test -- --verbose`
   Attached excerpt: `evidence/c6a29e00-self-hosting-test-2026-04-08.excerpt.txt`
   Result summary from excerpt: `Passed:  77`, `Failed:  1`, `Total:   78`
   Failure lines from excerpt: `FUNC_TEST:snix-compile:FAIL:exit or no binary at /bin/snix`, `error: builder for '1l8vldf9v2134669b48kwnscg9f7jid4-snix-self-compiled' failed (exit code 101)`, `Compiling proc-macro2 v1.0.106`, `Compiling quote v1.0.45`

Historical notes from the earlier 2026-04-07 investigation still stand for the already-fixed groups, but tasks 4.7-4.9 and 5.4 now also have direct attached rerun evidence under `evidence/`.

- [x] 7.1 Fix cc-dep-build: diagnose cc-rs exit=1 under scheme-only sandbox
- [x] 7.2 Fix rg-build: diagnose why binary not at output path (exit=0 but no binary)
- [x] 7.3 Fix source-rebuild: diagnose exit=1 from snix system rebuild --source
- [ ] 7.4 Fix snix-compile: diagnose why binary not at expected output path
- [x] 7.5 Document remaining failures and root causes
- [x] 7.6 Update AGENTS.md with new snix builder knowledge
