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

## Self-hosting validation attempt (2026-04-16)

- Tree under test: current `main` at `9c3f2325`
- Command:
  - `TMPDIR=/var/tmp nix run .#self-hosting-test -- --verbose`
- Capture dir:
  - `/var/tmp/redox-self-hosting-captures/20260416T165825-self-hosting-test/`
- Committed excerpt:
  - `2026-04-16-self-hosting-test-fail.excerpt.txt`
- Summary from excerpt/capture:
  - `buildfs: proxy mode active`
  - `FUNC_TEST:cc-dep-build:FAIL:exit=1`
  - `FUNC_TEST:workspace-build:FAIL:exit=1`
  - `FUNC_TEST:rg-build:PASS`
  - `Results: 68 passed, 2 failed, 0 skipped`
  - `Total time: 6000.084s`
- Current read: boot and broad self-hosting coverage still run under proxy mode, but the change is not rebaselined yet because the first proxy-active self-hosting attempt regressed earlier than the known `snix-compile` timeout path.
- Comparison against `snix-sandbox-test`: both profiles import the same `self-hosting.nix` base and mount the same `cc-dep-test` / `workspace-test` bundles, so the current divergence is not explained by static package-set or fixture-content drift. The strongest code-level differences are in the test harness: `self-hosting-test.nix` captures `snix build` output via command substitution and only prints the first 20 stderr lines for these failures, while `snix-sandbox-test.nix` saves stdout/stderr to files, dumps `snix-debug.log`, and includes direct-script / expr probes around the same fixtures.
- The visible `/nix/system/profile/bin/chmod: No such file or directory` line came from the earlier `snix-build-cargo` fixture drift in `self-hosting-test.nix`; it is worth fixing, but it does not match the `cc-dep` / `workspace` builder scripts, which do not call `chmod` and are already run via `bash` argv.

## Remaining validation gap

- The focused `proxy_namespace_test` reproducer exists in tree, but this `snix-sandbox-test` profile proves the workload side of the change, not the dedicated reproducer path.
- The 2026-04-16 self-hosting rerun preserved the required capture artifacts, but it failed in `cc-dep-build` and `workspace-build` before it could serve as a passing proxy-active self-hosting proof.
- Next step for task 3.3: port the stronger `cc-dep-build` / `workspace-build` diagnostics from `snix-sandbox-test.nix` into `self-hosting-test.nix` (stdout/stderr files, `snix-debug.log`, and if useful the direct-script / expr probes), then rerun `self-hosting-test` until at least one proxy-active pass completes.
