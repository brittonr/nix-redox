## 1. Diagnose all 16 failures with verbose output

- [x] 1.1 Run the test suite with `--verbose` and capture full stderr for each failing test into a log file
- [x] 1.2 Extract the snix error message for each failure (the exit=1 stderr, not just the FUNC_TEST line)
- [x] 1.3 Classify each failure by root cause: directory-output, flake-eval, sandbox-gap, rebuild-bug, or test-script-bug

## 2. Fix directory output derivations (`snix-build-dir`)

- [x] 2.1 Read the `snix-build-dir` stderr from the verbose log — identify whether it's an output verification issue, NAR hash issue, or builder failure
- [x] 2.2 Read `snix-redox/src/local_build.rs` output verification code — check how it handles `$out` as a directory vs a file
- [x] 2.3 Implement the fix in `local_build.rs`
- [x] 2.4 Rebuild and verify `snix-build-dir` passes

## 3. Fix flake installable builds (`flake-build`, `flake-cached`, `flake-registered`)

- [x] 3.1 Read the `flake-build` stderr from the verbose log — identify whether it's eval failure, input resolution, or build failure
- [x] 3.2 Read `snix-redox/src/flake.rs` — trace the flake evaluation path for `/usr/src/test-flake#hello`
- [x] 3.3 Check the test flake contents on the disk image (`/usr/src/test-flake/flake.nix`, `flake.lock`)
- [x] 3.4 Implement the fix in `flake.rs` or the test flake definition
- [ ] 3.5 Rebuild and verify `flake-build` passes (which should cascade to `flake-cached` and `flake-registered`)

## 4. Fix sandbox gaps for cargo builds (`snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build`)

- [x] 4.1 Read the `snix-build-cargo` and `cc-dep-build` stderr — identify which file access the sandbox blocked or which env var is missing
- [x] 4.2 Read `snix-redox/src/build_proxy/allow_list.rs` — check what paths are currently allowed for builders
- [x] 4.3 Read `snix-redox/src/local_build.rs` — check what environment variables are set for the builder process
- [x] 4.4 Compare the sandbox environment with what a direct `cargo build` gets (the working cargo tests from the rustc fix prove cargo itself works)
- [x] 4.5 Add missing paths to the sandbox allow-list (likely: linker, sysroot, LLVM tools, cargo home)
- [x] 4.6 Add missing environment variables to the builder (likely: CC, AR, RUSTFLAGS, LD_LIBRARY_PATH)
- [ ] 4.7 Rebuild and verify `snix-build-cargo` passes
- [ ] 4.8 Verify `cc-dep-build` and `workspace-build` pass
- [ ] 4.9 Verify `rg-build` passes (and downstream `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`)

Note: /dev/null EXDEV fix in daf86cc4 resolved sandbox device path access. All cargo-based
builds now proceed past initialization (0 failures at timeout). Need longer test timeout
for 168-crate snix and 33-crate ripgrep builds.

## 5. Fix source-based rebuild (`source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg`)

- [x] 5.1 Read the `source-rebuild` stderr from the verbose log
- [x] 5.2 Read `snix-redox/src/rebuild.rs` `rebuild_from_source()` — trace the failure path
- [x] 5.3 Implement the fix (likely depends on fixes from tasks 2-4 since rebuild invokes snix build internally)
- [x] 5.4 Rebuild and verify `source-rebuild` passes (cascades to `source-rebuild-gen` and `source-rebuild-pkg`)

## 6. Fix snix self-compile (`snix-compile`)

- [x] 6.1 Read the `snix-compile` stderr — determine if it's a timeout, sandbox issue, or build failure
- [x] 6.2 If sandbox issue: apply same fixes as task 4. If timeout: increase test timeout or optimize build.
- [ ] 6.3 Rebuild and verify `snix-compile` passes

Note: snix-compile now proceeds past sandbox init but needs ~900s+ for 168 crates.
Test timeout (1800s) is reached before all tests complete.

## 7. End-to-end validation

- [ ] 7.1 Run the full 78-test suite and confirm ≥72 pass (all except potential timeout-sensitive tests)
- [ ] 7.2 Document any remaining failures and their root causes
- [ ] 7.3 Update AGENTS.md with new snix builder knowledge
