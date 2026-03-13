## Why

The fork-lock fix (`patch-relibc-fork-lock.py`) and lld-wrapper are deployed and all 12 parallel-build-tests pass (JOBS=2, up to 100-crate workspaces). But the self-hosting test's `parallel-jobs2` test still crashes with `fatal runtime error: failed to initiate panic, error 0`. The cc wrapper already routes through `lld-wrapper` for the 16MB stack, so the crash has a different cause — needs diagnosis. The two investigation changes (`cargo-parallel-hang-investigation`, `fix-remaining-os-bugs`) have open tasks that are effectively complete or permanently deferred and should be archived.

## What Changes

- Diagnose and fix the `parallel-jobs2` self-hosting test crash (cc wrapper path, JOBS=2)
- Build and run the full self-hosting test to validate JOBS=2 end-to-end
- Archive `cargo-parallel-hang-investigation` (16/27 tasks checked, remaining are done or superseded by the fork-lock fix)
- Archive `fix-remaining-os-bugs` (24/30 tasks checked, remaining are blocked/deferred kernel instrumentation)
- Update AGENTS.md and napkin to reflect final state

## Capabilities

### New Capabilities
- `parallel-cargo-validation`: End-to-end validation that JOBS=2 works across the full self-hosting test suite, with the parallel-jobs2 crash diagnosed and fixed

### Modified Capabilities

## Impact

- `nix/pkgs/userspace/redox-sysroot.nix` — cc wrapper may need changes depending on crash root cause
- `nix/redox-system/profiles/self-hosting-test.nix` — parallel-jobs2 test should flip from FAIL to PASS
- `openspec/changes/cargo-parallel-hang-investigation/` — archive
- `openspec/changes/fix-remaining-os-bugs/` — archive
- `AGENTS.md` — update parallel build section
- `.agent/napkin.md` — update parallel-jobs2 entry
