# Evidence — codify-self-hosting-proof-artifacts

## Current contract verification on the working tree

The new wrapper + helper contract was exercised on the current tree with two focused runs and one full run. All three runs produced the required capture files even though the underlying self-hosting tests currently fail for unrelated reasons.

### Focused run
- Command: `TMPDIR=/var/tmp nix run .#snix-compile-test -- --verbose`
- Capture dir: `/var/tmp/redox-self-hosting-captures/20260414T004549-snix-compile-test`
- Required files present: `meta.txt`, `runner.log`, `serial.log`, `vmm.log`, `host-monitor.log`, `summary.json`, `excerpt.txt`
- Attached excerpt: `2026-04-14-snix-compile-current-fail.excerpt.txt`
- Key result: contract files emitted; test verdict `FAIL` because `snix-compile` regressed on the current tree

### Focused sandbox run
- Command: `TMPDIR=/var/tmp nix run .#snix-sandbox-test -- --verbose`
- Capture dir: `/var/tmp/redox-self-hosting-captures/20260414T004002-snix-sandbox-test`
- Required files present: `meta.txt`, `runner.log`, `serial.log`, `vmm.log`, `host-monitor.log`, `summary.json`, `excerpt.txt`
- Attached excerpt: `2026-04-14-snix-sandbox-current-fail.excerpt.txt`
- Key result: contract files emitted; suite verdict `FAIL` on the current tree, with 13 pass / 4 fail recorded in `summary.json`

### Full run
- Command: `TMPDIR=/var/tmp nix run .#self-hosting-test -- --verbose`
- Capture dir: `/var/tmp/redox-self-hosting-captures/20260414T004855-self-hosting-test`
- Required files present: `meta.txt`, `runner.log`, `serial.log`, `vmm.log`, `host-monitor.log`, `summary.json`, `excerpt.txt`
- Attached excerpt: `2026-04-14-self-hosting-current-fail.excerpt.txt`
- Key result: contract files emitted; suite verdict `FAIL` on the current tree, with 57 pass / 12 fail recorded in `summary.json`

## Passing artifact examples

The helper was also used to backfill `summary.json` + `excerpt.txt` for the known-good 2026-04-09 proof captures so the latest-success index has concrete passing entries for the major proof flows. That exercises the success-path post-processing logic which refreshes `docs/self-hosting/latest-success.{json,md}` when a finalized capture has verdict `pass`.

### Focused pass example
- Source capture: `/var/tmp/redox-self-hosting-captures/20260409T115513-snix-compile-test`
- Attached excerpt: `2026-04-09-snix-compile-pass.excerpt.txt`
- Attached summary: `2026-04-09-snix-compile-pass.summary.json`
- Result: `7/7 pass`

### Full pass example
- Source capture: `/var/tmp/redox-self-hosting-captures/20260409T133254-self-hosting-test`
- Attached excerpt: `2026-04-09-self-hosting-pass.excerpt.txt`
- Attached summary: `2026-04-09-self-hosting-pass.summary.json`
- Result: `78/78 pass`

## Latest-success index snapshot

Successful proof captures now refresh:
- `docs/self-hosting/latest-success.json`
- `docs/self-hosting/latest-success.md`

Attached snapshots:
- `latest-success.json`
- `latest-success.md`

At snapshot time the index points to:
- `snix-compile-test` -> `/var/tmp/redox-self-hosting-captures/20260409T115513-snix-compile-test`
- `snix-sandbox-test` -> `/var/tmp/redox-self-hosting-captures/20260409T124808-snix-sandbox-test`
- `self-hosting-test` -> `/var/tmp/redox-self-hosting-captures/20260409T133254-self-hosting-test`
