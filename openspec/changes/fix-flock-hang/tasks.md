## 1. Verify flock is already a no-op

- [x] 1.1 Find the `flock()` implementation in relibc source — confirmed `Sys::flock()` in `src/platform/redox/mod.rs:306` already returns `Ok(())` (no-op) in upstream relibc
- [x] 1.2 No patch needed — flock was never the hang source. The hangs were from a waitpid/process scheduling issue on KVM: foreground process execution and bare `wait` both deadlock when the parent is idle.
- [x] 1.3 N/A — no patch to add to relibc.nix

## 2. Replace cargo-build-safe with polling pattern

- [x] 2.1 Remove the `cargo-build-safe` script creation block from `self-hosting-test.nix`
- [x] 2.2 Replace all 9 cargo-build-safe invocations with inline poll-wait pattern: `cmd & PID=$!; while kill -0 $PID; do cat /scheme/sys/uname; done; wait $PID`
- [x] 2.3 Verify no `cargo-build-safe` references remain in the file

## 3. Build and validate

- [x] 3.1 N/A — no relibc changes needed (flock already a no-op in upstream)
- [x] 3.2 Build the self-hosting test image: `nix build .#self-hosting-test`
- [x] 3.3 Boot the VM on Cloud Hypervisor (KVM) and run the self-hosting test suite — 57/62 PASS, 5 rg-build failures (pre-existing build error, not a hang), FUNC_TESTS_COMPLETE in 896s
- [x] 3.4 All cargo builds pass without hangs: realtest, multifile, minigrep, buildrs, env-pkg, heavyfork, pathdep, vendored, procmacro, snix-compile (193 crates), parallel-jobs2

## 4. Update documentation

- [x] 4.1 Update `AGENTS.md` — document the real root cause (waitpid scheduling, not flock), update workaround description
- [x] 4.2 Update `.agent/napkin.md` — move cargo-build-safe entry to fixed, add waitpid finding
