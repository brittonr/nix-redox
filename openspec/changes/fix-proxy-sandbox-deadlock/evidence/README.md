# Evidence for `fix-proxy-sandbox-deadlock`

## Current sandbox validation (2026-04-16)

- Tree under test: current `main` at `047fd36e`
- Command:
  - `TMPDIR=/var/tmp nix run .#snix-sandbox-test -- --verbose`
- Capture dir:
  - `/var/tmp/redox-self-hosting-captures/20260416T154023-snix-sandbox-test/`
- Committed excerpt:
  - `2026-04-16-snix-sandbox-test.excerpt.txt`
- Summary from excerpt:
  - `buildfs: proxy mode active`
  - `FUNC_TEST:cc-dep-build:PASS`
  - `FUNC_TEST:workspace-build:PASS`
  - `FUNC_TEST:rg-build:PASS`
  - `Passed:  17`
  - `Failed:  0`
  - `Total:   17`
- Dirty-tree note: the run recorded `git_dirty: true` because local agent/autoresearch metadata files were present; no `snix-redox/` or `nix/redox-system/` validation code under test was dirty during the run.

## Remaining validation gap

- The focused `proxy_namespace_test` reproducer exists in tree, but this `snix-sandbox-test` profile proves the workload side of the change, not the dedicated reproducer path.
- One self-hosting validation rerun with proxy mode active is still pending before this change can be considered fully rebaselined.
