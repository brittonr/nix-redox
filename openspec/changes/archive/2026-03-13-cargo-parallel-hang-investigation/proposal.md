## Why

`cargo build` with JOBS>1 hangs indefinitely on multi-crate projects when running on Redox OS. Single-crate builds now work at JOBS=2 (lld-wrapper fixed linker stack overflows), but workspace builds consistently hang at ~115-136 crates. The JOBS=1 workaround makes self-hosted compilation 2-4x slower than it needs to be. Fixing this is the main remaining blocker for practical self-hosting performance.

## What Changes

- Add diagnostic instrumentation to relibc's `poll()`, `waitpid()`, and pipe operations to capture the exact hang point during JOBS>1 cargo builds
- Add a strace-like syscall tracer (or extend existing debug infrastructure) that logs process states when a hang is detected
- Build a reproducer test harness that reliably triggers the hang in the VM test environment and captures diagnostics
- Based on findings, fix the root cause in relibc (likely `poll()` pipe multiplexing or `waitpid()` notification) or cargo's job manager
- Validate the fix by running the parallel-build-test workspace at JOBS=2 to completion
- Remove or relax the JOBS=1 constraint from self-hosting profiles once validated

## Capabilities

### New Capabilities
- `parallel-hang-diagnostics`: Instrumentation and tooling to detect, reproduce, and capture diagnostic data when cargo hangs at JOBS>1 on multi-crate builds
- `parallel-build-fix`: The actual fix to relibc/cargo that eliminates the JOBS>1 hang on workspace builds

### Modified Capabilities

## Impact

- **relibc**: Likely patches to `poll()` implementation, pipe buffer management, or `waitpid()` notification path
- **cargo patches**: May need updates to read2-pipes or jobserver-poll patches depending on findings
- **self-hosting profiles**: CARGO_BUILD_JOBS can be raised from 1 once fix is validated
- **parallel-build-test profile**: Workspace JOBS=2 test moves from expected-hang to expected-pass
- **kernel**: Possible changes if the issue traces to proc: scheme waitpid notification or pipe scheme buffer management
