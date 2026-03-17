## Context

The system management stack has been built in layers over the past week: rebuild routing, activate (profile swap + config files + activation scripts + service diffs), generations, GC, boot component tracking. Each layer has thorough unit tests (607 total) but the only VM tests that touch rebuild are rebuild-generations-test.nix (hostname changes, generation counting, GC roots) and bridge-rebuild-test.nix (host-side bridge path). Neither test environment.etc file injection, activation script execution, or service change detection on a live system.

The functional-test.nix profile declares environment.etc entries and activation scripts in its module config, but the test scripts (01-shell.ion through 20-proxy-ns.ion) never check whether those files landed on disk or those scripts ran.

## Goals / Non-Goals

**Goals:**
- Prove that `snix system rebuild` drives the full activate pipeline on a running Redox VM: config file writes, activation script execution, service diff reporting, generation creation
- Prove no-op rebuild detection works (second rebuild with identical config produces no changes)
- Prove rollback restores prior state (etc files, hostname, generation pointer)
- Catch regressions where unit-tested logic doesn't survive the real Redox runtime (Ion shell, relibc, scheme I/O)

**Non-Goals:**
- Bridge rebuild path (already covered by bridge-rebuild-test.nix)
- Package addition/removal via bridge (requires host-side build daemon)
- Boot component changes that need reboot (covered by boot-generation-select-test.nix)
- Network-based operations (covered by network-test, https-cache-test)

## Decisions

**Single profile, linear test script**: One test profile with a self-contained Ion test script, same pattern as all other test profiles. The script runs phases sequentially — verify initial state, mutate config, rebuild, verify changes, rebuild again (no-op), rollback, verify restoration. This matches the proven FUNC_TEST protocol the test runner already understands.

**Test via `--config` JSON, not Nix eval**: The rebuild command accepts `--config /path/to/json` which bypasses Nix evaluation and goes straight to merge+activate. This is the same path rebuild-generations-test.nix uses. Testing the Nix eval path requires the evaluator to parse configuration.nix at runtime — already covered by existing tests. The JSON path isolates what we're actually testing: the activate pipeline.

**Verify side effects on disk, not stdout parsing**: Check `/etc/hostname`, read marker files from activation scripts, verify etc files exist with correct content. Don't rely on parsing snix stdout (fragile, Ion pipe issues). Write a bash helper script for checks that need string manipulation (Ion's `$()` crashes on empty output, no `sed`).

**Reuse existing test infrastructure**: `mkFunctionalTest` + `mkSystem` + the FUNC_TEST protocol. No new Nix infrastructure needed.

## Risks / Trade-offs

**[Risk] Ion shell limitations break test assertions** → Write complex checks in bash helper scripts invoked from Ion. Keep Ion logic to simple `exists -f` / `grep -q` / `test $? = 0` patterns.

**[Risk] Timing — activation scripts run asynchronously** → They don't. `run_activation_scripts()` executes synchronously in topo-sort order. The marker file will exist before activate returns.

**[Risk] Test profile disk size** → No additional packages needed. Config-only changes fit in the standard 768MB image.
