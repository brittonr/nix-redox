## 1. Rebaseline the current self-hosting suite

- [x] 1.1 Let the current `nix run .#self-hosting-test` finish, or re-run it if the host-side build/cache path invalidates the result.
- [x] 1.2 Capture the completed result set: pass, fail, timeout, and host-infrastructure failures.
- [x] 1.3 Classify each remaining failure as one of: flake bug, builder-path bug, rebuild bug, timeout, or host-cache noise.
- [x] 1.4 Update `openspec/changes/fix-snix-build-gaps/tasks.md` so the open tasks describe the real post-rollback failure set.

Initial partial run (before test reorder):
  64 pass, 1 explicit fail (cc-dep-build), 13 timeout/not-reached
Final full run (after test reorder, all 78 report):
  65 pass, 13 fail
  Pass: rustc-exists, cargo-exists, cc-exists, lld-exists, clang-exists,
    sysroot-exists, sysroot-libc, sysroot-headers, sysroot-crt,
    rustc-driver-so, cargo-config, rand-scheme, rand-read,
    rustc-version, rustc-print-cfg, two-step-compile, hello-two-step,
    alloc-shim, rust-command-fork, rustc-direct-link, environ-diag,
    cargo-probe-cmd, cargo-probe-bt, cargo-probe-target, cargo-build,
    cargo-direct-no-wrapper, binary-exists, binary-runs, real-program,
    multifile-build, buildscript, minigrep, cargo-buildrs, env-pkg-name,
    env-propagation-simple, env-heavy-fork, env-propagation-heavy,
    cargo-path-dep, cargo-vendored-dep, cargo-proc-macro, snix-version,
    snix-build-simple, snix-build-store-path, snix-build-registered,
    snix-build-dir, snix-build-cached, snix-build-dep, snix-build-exec,
    snix-build-file, snix-build-fail, snix-build-cargo, test-flake-present,
    flake-build, flake-cached, flake-registered, cc-dep-src-present,
    workspace-src-present, workspace-build, snix-src-present, snix-vendor-present
  Fail: cc-dep-build (exit=1, builder-path bug: cc-rs sandbox issue)
  Fail (now with full results after test reorder):
    cc-dep-build (exit=1), rg-build (no binary at output path),
    rg-version, rg-search, rg-store-path, rg-binary-size (no binary),
    source-rebuild (exit=1), source-rebuild-gen, source-rebuild-pkg,
    snix-compile (binary not at expected path),
    snix-binary-exists, snix-eval-works (no binary)
  Pass added by reorder: parallel-jobs2, source-rebuild-dry,
    rg-src-present, rg-vendor-present

## 2. Fix the immediate `snix-redox` stabilization bugs

- [x] 2.1 Remove stale proxy-only plumbing from `snix-redox/src/local_build.rs` or fix it so host builds compile cleanly in the non-Redox path.
- [x] 2.2 Fix GitLab forge tarball URL generation in `snix-redox/src/flake.rs`.
- [x] 2.3 Strengthen the forge URL unit tests so GitLab URLs are checked exactly, not with loose substring assertions.
- [x] 2.4 Thread sandbox-control options through flake installables so `snix build --no-sandbox .#attr` uses the same local-build path as `--expr` and `--file`.
- [x] 2.5 Fix `snix-redox/src/sandbox.rs` comments/docs so they match the current scheme list and the disabled proxy status.

## 3. Re-run focused self-hosting verification

- [x] 3.1 Re-run the flake tests: `flake-build`, `flake-cached`, and `flake-registered`.
- [x] 3.2 Re-run cargo/workspace validation: `snix-build-cargo`, `cc-dep-build`, `workspace-build`, and `rg-build`.
- [x] 3.3 Re-run `source-rebuild`, `source-rebuild-gen`, and `source-rebuild-pkg` under the current builder path.
- [x] 3.4 Decide whether `snix-compile` is a correctness failure or only a timeout/expectation problem, then update the test plan accordingly.

Full results (reordered run, all 78 tests report):
- flake-build, flake-cached, flake-registered: all PASS
- snix-build-cargo: PASS; cc-dep-build: FAIL (exit=1); workspace-build: PASS
- rg-build: FAIL (exit=0 but no binary at output path)
- rg-version, rg-search, rg-store-path, rg-binary-size: FAIL (no binary)
- parallel-jobs2: PASS
- source-rebuild: FAIL (exit=1); source-rebuild-gen, source-rebuild-pkg: FAIL (rebuild failed)
- source-rebuild-dry: PASS
- snix-compile: FAIL (binary not at expected path); snix-binary-exists, snix-eval-works: FAIL

## 4. Record the stabilized self-hosting baseline

- [x] 4.1 Run the full self-hosting suite again and record the final baseline under the current scheme-only sandbox model.
- [x] 4.2 Update `openspec/changes/fix-snix-build-gaps/proposal.md` and `tasks.md` with the final remaining blockers, if any.
- [x] 4.3 Update `AGENTS.md` with any new self-hosting builder knowledge that changed the debugging approach.

## 5. Re-sequence the expansion roadmap

- [x] 5.1 Update `openspec/changes/nix-self-hosting-roadmap/proposal.md` so phase-two work starts after the stabilized baseline, not in parallel with it.
- [x] 5.2 Reorder `openspec/changes/nix-self-hosting-roadmap/tasks.md` so remote cache, `stored`, generation management, and rollback are explicitly blocked on stabilization exit criteria.
- [x] 5.3 Summarize the new execution order in the proposal/design so future sessions keep self-hosting ahead of hardware and other side tracks.
