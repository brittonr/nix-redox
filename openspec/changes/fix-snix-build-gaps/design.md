## Context

After fixing rustc/snix init panics (62/78 tests pass), 16 tests still fail with exit=1. All are snix builder functional issues. The test run gives us precise failure modes for each group.

Aspen's `aspen-snix-bridge` uses snix as a library — its gRPC bridge wraps snix's `BlobService`, `DirectoryService`, and `PathInfoService` traits with Aspen storage backends. The bridge delegates evaluation and building to snix's core pipeline. This means fixes to snix's builder directly benefit both standalone Redox self-hosting and Aspen's distributed build infrastructure.

## Goals / Non-Goals

**Goals:**
- Diagnose and fix all 16 remaining test failures (exit=1)
- Get `snix build` working for directory outputs, flake installables, and cargo-based derivations
- Get ripgrep 33-crate build working end-to-end via snix
- Get `snix system rebuild --source` working for dry-run and actual rebuild

**Non-Goals:**
- Remote HTTP binary cache client (roadmap task 2)
- Store scheme daemon (roadmap task 3)
- Performance optimization of the sandbox proxy
- TLS/HTTPS support (no CA certs on Redox, by design)

## Decisions

### 1. Diagnose-first with verbose test run

Run the test suite with `--verbose` and capture stderr for each failing test. The exit=1 errors will have specific error messages from snix that reveal the root cause — unlike the old exit=134 aborts which gave no useful output.

### 2. Group fixes by root cause, not by test name

The 16 failures cluster into ~4 root causes. Fix each root cause to unblock a batch of tests rather than fixing tests one-by-one.

**Expected clusters:**
- **Directory output handling** — `snix-build-dir` (1 test). Likely `local_build.rs` output verification doesn't handle `$out` as a directory correctly.
- **Flake evaluation** — `flake-build`, `flake-cached`, `flake-registered` (3 tests). Likely `flake.rs` input resolution or eval issue on Redox.
- **Sandbox environment for cargo builds** — `snix-build-cargo`, `cc-dep-build`, `workspace-build`, `rg-build` + 4 downstream (8 tests). Likely sandbox allow-list missing paths that cargo/cc-rs need (linker, sysroot, temp dirs).
- **Source rebuild** — `source-rebuild`, `source-rebuild-gen`, `source-rebuild-pkg` (3 tests). Likely `rebuild.rs` issue with source-mode evaluation or build.
- **snix self-compile** — `snix-compile` (1 test). May be timeout or sandbox issue with 168-crate build.

### 3. Fix in snix-redox source, not patches

Unlike the ld_so fix (which required patching relibc's upstream source), these are all in our own `snix-redox/` crate. Fix directly in source, rebuild, and test.

### 4. Iterate within one VM boot when possible

The test suite boots a VM, runs all tests sequentially, and reports. For diagnosis, we can add `strace` or extra logging to specific tests. For quick iteration, modify the test script to run only the failing subset.

## Alternatives Considered

**Skip sandbox for complex builds** — Could add `--no-sandbox` for cargo-based builds. Rejected — the sandbox works for simple builds, so the gap is likely a specific missing allow-list entry, not a fundamental limitation.

**Use bridge builds for complex cases** — Could delegate cargo builds to the host via virtio-fs bridge. Rejected — the whole point of self-hosting is building ON Redox. Bridge is a fallback, not the goal.
