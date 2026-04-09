# Evidence for `fix-snix-build-gaps`

Committed evidence artifacts captured from the historical exact reruns on 2026-04-08 and the closing reruns on 2026-04-09.
The checked-in files below are compact excerpts copied from the rerun output.

## Current post-fix reruns (2026-04-09)

### 1. Focused sandbox rerun
- Tree under test: current working tree after the no-CA source-bundle fix and before the later full-suite timeout bump
- Command:
  - `nix run .#snix-sandbox-test -- --verbose`
- Capture dir:
  - `/var/tmp/redox-self-hosting-captures/20260409T124808-snix-sandbox-test/`
- Committed excerpt:
  - `2026-04-09-snix-sandbox-test.excerpt.txt`
- Summary from excerpt:
  - `Passed:  6`
  - `Failed:  0`
  - `Total:   6`
  - `FUNCTIONAL TEST PASSED`

### 2. Full self-hosting rerun
- Tree under test: current working tree after the no-CA source-bundle fix and after the later full-suite timeout bump
- Command:
  - `nix run .#self-hosting-test -- --verbose`
- Capture dir:
  - `/var/tmp/redox-self-hosting-captures/20260409T133254-self-hosting-test/`
- Committed excerpt:
  - `2026-04-09-self-hosting-test.excerpt.txt`
- Summary from excerpt:
  - `Passed:  78`
  - `Failed:  0`
  - `Total:   78`
- The excerpt also includes:
  - `snix-compile:PASS`
  - `snix-binary-exists:PASS`
  - `snix-binary-runs:PASS`
  - `snix-eval-works:PASS`
  - `source-rebuild:PASS`
  - `source-rebuild-gen:PASS`
  - `source-rebuild-pkg:PASS`
  - `source-rebuild-dry:PASS`

## Exact-commit reruns (`c6a29e00`)

### 1. Focused sandbox rerun
- Commit: `c6a29e00`
- Worktree: `/tmp/redox-c6a29e00`
- Command:
  - `cd /tmp/redox-c6a29e00 && nix run .#snix-sandbox-test -- --verbose`
- Committed excerpt:
  - `c6a29e00-snix-sandbox-test-2026-04-08.excerpt.txt`
- Summary from excerpt:
  - `Passed:  6`
  - `Failed:  0`
  - `Total:   6`
  - `FUNCTIONAL TEST PASSED`

### 2. Full self-hosting rerun
- Commit: `c6a29e00`
- Worktree: `/tmp/redox-c6a29e00`
- Command:
  - `cd /tmp/redox-c6a29e00 && nix run .#self-hosting-test -- --verbose`
- Committed excerpt:
  - `c6a29e00-self-hosting-test-2026-04-08.excerpt.txt`
- Summary from excerpt:
  - `Passed:  77`
  - `Failed:  1`
  - `Total:   78`
- The excerpt also includes:
  - downstream ripgrep checks: `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`
  - `parallel-jobs2:PASS`
  - `snix-binary-exists:PASS`, `snix-binary-runs:PASS`, `snix-eval-works:PASS`
  - `source-rebuild:PASS`, `source-rebuild-gen:PASS`, `source-rebuild-pkg:PASS`, `source-rebuild-dry:PASS`
- Relevant failure lines in the excerpt:
  - `FUNC_TEST:snix-compile:FAIL:exit or no binary at /bin/snix`
  - `error: builder for '1l8vldf9v2134669b48kwnscg9f7jid4-snix-self-compiled' failed (exit code 101)`
  - `Compiling proc-macro2 v1.0.106`
  - `Compiling quote v1.0.45`

## Exploratory dirty-tree rerun (not baseline)

This run was captured while experimental uncommitted `snix-compile` fixture edits were present in the working tree. Those edits were later discarded, so this run is not used as evidence for the committed baseline.
