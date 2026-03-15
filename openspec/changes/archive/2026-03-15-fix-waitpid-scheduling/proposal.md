## Why

Every cargo build on Redox requires a 3-line poll-wait workaround: `cmd & PID=$!; while kill -0 $PID; do cat /scheme/sys/uname; done; wait $PID`. Without this, foreground process execution and bare `wait` deadlock when the parent is idle on KVM. The workaround is sprinkled across 9+ call sites in the self-hosting test and the ripgrep builder script. It works but adds complexity, wastes CPU on polling, and masks a kernel/relibc bug that could surface in other process hierarchies (snix building derivations, shell scripts calling subprocesses, etc.).

## What Changes

- Diagnose the root cause of the foreground process hang on KVM — the userspace procmgr's event loop stalls when the system is idle, preventing it from processing waitpid SQEs
- Determine if the bug is in the kernel's SQE delivery (not waking the scheme daemon), the scheduler's handling of HLT'd vCPUs, or the procmgr's event loop itself
- Fix the root cause so that `wait $PID` works without active polling
- Remove the poll-wait workaround from `build-ripgrep.sh` and test scripts
- Validate that cargo builds complete without hanging using plain `wait`

## Capabilities

### New Capabilities

- `waitpid-fix`: Fix procmgr event loop starvation on KVM so that parent processes can block on `waitpid()` without active scheme I/O polling. Covers SQE delivery to the userspace procmgr, scheduler wake behavior for HLT'd vCPUs, and the procmgr's event loop responsiveness.

### Modified Capabilities

None — `parallel-cargo-builds` and `nix-derivation-builds` specs describe the build pipeline behavior, not the wait mechanism. The fix is below the abstraction level of those specs.

## Impact

- Redox kernel: SQE delivery to userspace schemes, scheduler wake for HLT'd vCPUs
- `bootstrap/src/procmgr.rs` — may need instrumentation, unlikely to need code changes (waitpid implementation is correct)
- `nix/pkgs/infrastructure/build-ripgrep.sh` — remove poll-wait pattern
- `nix/redox-system/profiles/self-hosting-test.nix` — remove 16 poll-wait patterns, replace with plain `wait $PID`
- `snix-redox/src/local_build.rs` — potentially remove `Stdio::inherit()` workaround if pipe-based `cmd.output()` becomes safe
- All userspace programs that fork+wait benefit from the fix
