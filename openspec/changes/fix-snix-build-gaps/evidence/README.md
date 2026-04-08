# Evidence for `fix-snix-build-gaps`

Committed evidence artifacts captured from exact reruns on 2026-04-08.
The checked-in files below are compact excerpts copied from the rerun output.

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
- Relevant failure lines in the excerpt:
  - `FUNC_TEST:snix-compile:FAIL:exit or no binary at /bin/snix`
  - `error: builder for '1l8vldf9v2134669b48kwnscg9f7jid4-snix-self-compiled' failed (exit code 101)`
  - `Compiling proc-macro2 v1.0.106`
  - `Compiling quote v1.0.45`

## Exploratory dirty-tree rerun (not baseline)

This run was captured while experimental uncommitted `snix-compile` fixture edits were present in the working tree. Those edits were later discarded, so this run is not used as evidence for the committed baseline.
