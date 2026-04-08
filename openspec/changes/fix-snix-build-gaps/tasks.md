**Status: OPEN** — focused `snix-sandbox-test` passes 6/6, but full `self-hosting-test` does not complete within the 2400s timeout. Exact reruns of detached worktree commit `c6a29e00` and the current working tree stop after 70 reported tests while `snix self-compile` is still running. Tasks 6.3 and 7.4 are incomplete.

Evidence note: the checkboxes below reflect the original investigation plus targeted reruns from 2026-04-07. The exact post-change reruns captured on 2026-04-08 directly re-verify the focused sandbox subset and the current full-suite timeout behavior.

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

Note: exact reruns on 2026-04-08 show that the current committed/current-tree profile still
hits the 2400s suite timeout while `snix build --file` is running. The earlier
proc-macro/build-script abort (`failed to initiate panic, error 0`) is historical evidence,
but it is not the reproducible committed baseline until we hit it again on an exact rerun.

## 7. End-to-end validation (post-rollback baseline)

Current reproducible baseline after exact reruns on 2026-04-08:
- focused `snix-sandbox-test`: **6 pass, 0 fail** (all 6 tests report)
- full `self-hosting-test`: **tests did not complete** within the 2400s timeout; summary at timeout is **70 pass, 0 fail, 70 total reported**

Current remaining blocker after the exact reruns:
- `snix-compile`: still running when the full suite hits the 2400s timeout. The last serial lines before timeout are `--- snix self-compile: snix build --file ---` followed by repeated redoxfs `READ_BLOCK: POINTER IS NULL` diagnostics.

Verification evidence (direct reruns captured on 2026-04-08):

1. **Post-change focused rerun against detached worktree commit `c6a29e00`**
   Command: `cd /tmp/redox-c6a29e00 && nix run .#snix-sandbox-test -- --verbose`
   Result summary: `Passed:  6`, `Failed:  0`, `Total:   6`, `Total time: 243.237s`
   Tests: `snix-simple`, `snix-build-cargo`, `flake-build`, `cc-dep-build`, `workspace-build`, `rg-build`

2. **Post-change full rerun against detached worktree commit `c6a29e00`**
   Command: `cd /tmp/redox-c6a29e00 && nix run .#self-hosting-test -- --verbose`
   Result summary at timeout: `Passed:  70`, `Failed:  0`, `Total:   70`, `Total time: 2400.063s`, `TESTS DID NOT COMPLETE`
   Last serial lines show the suite stalled in `--- snix self-compile: snix build --file ---`

3. **Matching full rerun on the current working tree**
   Command: `cd /home/brittonr/git/redox && nix run .#self-hosting-test -- --verbose`
   Result summary at timeout: `Passed:  70`, `Failed:  0`, `Total:   70`, `Total time: 2400.052s`, `TESTS DID NOT COMPLETE`
   This means the exact-commit rerun result is still the current reproducible baseline.

Historical notes from the earlier 2026-04-07 investigation still stand for the already-fixed groups:
- focused sandbox rerun reached 6/6 once the cargo-build fixture issues were fixed
- `snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build`, and ripgrep downstream checks passed after the fixture/bundle fixes
- `source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg`, and `source-rebuild-dry` passed in the earlier targeted reruns
- an earlier session note claimed a `77/1` post-reorder baseline, but that result is not treated as the committed baseline because the exact reruns above do not reproduce it

- [x] 7.1 Fix cc-dep-build: diagnose cc-rs exit=1 under scheme-only sandbox
- [x] 7.2 Fix rg-build: diagnose why binary not at output path (exit=0 but no binary)
- [x] 7.3 Fix source-rebuild: diagnose exit=1 from snix system rebuild --source
- [ ] 7.4 Fix snix-compile: diagnose why binary not at expected output path
- [x] 7.5 Document remaining failures and root causes
- [x] 7.6 Update AGENTS.md with new snix builder knowledge
