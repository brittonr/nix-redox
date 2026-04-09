## Context

The exact detached-worktree rerun for commit `c6a29e00` established the current evidence-backed baseline at `77/78` self-hosting tests passing, with `snix-compile` as the lone remaining failure. A later single-job experiment changed the failure shape enough that the full suite no longer finished within the 2400 second timeout, so the real blocker had to be isolated.

A focused `snix-compile-test` runner now reproduces the failure in about 1169 seconds with durable logs under `/var/tmp/redox-self-hosting-captures/20260408T205802-snix-compile-focus/`. That focused run shows the self-compiled derivation exiting 101 while building `libmimalloc-sys`, specifically during mimalloc C compilation in `c_src/mimalloc/v2/src/static.c`, with clang/stdatomic errors about non-trivially-copyable `_Atomic(...)` types. The installed `/bin/snix` in the profile still works; only the self-built derivation fails.

## Goals / Non-Goals

**Goals:**
- Turn the remaining `snix-compile` blocker into a concrete, evidence-backed allocator compatibility problem
- Find the smallest Redox-safe fix that lets the self-built `snix` derivation complete
- Keep validation fast by using the focused `snix-compile-test` runner before spending time on the full `self-hosting-test` suite
- Preserve existing `snix` CLI behavior on Redox (`--version`, `eval`, build path)

**Non-Goals:**
- Reworking the wider self-hosting suite beyond what is needed to validate the allocator fix
- Changing allocator choices on non-Redox hosts unless unavoidable for shared dependency wiring
- Solving unrelated future self-hosting roadmap items (remote cache, generation management, sandbox redesign)

## Decisions

### 1. Use the focused `snix-compile-test` runner as the primary validation harness

**Choice:** Reproduce and validate allocator fixes with `.#snix-compile-test` first, then rerun `.#self-hosting-test` only after the focused run passes.

**Rationale:** The full suite now times out before it can conclusively report the current blocker. The focused harness inherits the same self-hosting base image and source bundle path, but removes the 70 earlier smoke tests from the critical path.

**Alternative:** Keep iterating only with the full self-hosting suite.
That was rejected because it costs ~40 minutes per attempt and can fail without reaching a `snix-compile` verdict.

**Implementation:** Keep the focused runner and durable `/var/tmp/redox-self-hosting-captures/...` logs as the default evidence path while this change is active.

### 2. Evaluate allocator fixes in priority order from least invasive to most invasive

**Choice:** Investigate Redox-only dependency or feature selection first, then targeted downstream patching of `libmimalloc-sys` / mimalloc only if allocator selection cannot avoid the C failure.

**Rationale:** A feature-level fix is easier to maintain than carrying a long-lived vendor patch against mimalloc C sources. The new evidence suggests the blocker is isolated to allocator C compilation, not to the general Rust/C build path.

**Alternatives:**
- Patch Redox headers or clang behavior globally. Rejected because that would be cross-cutting and risk unrelated C builds.
- Carry a large local fork of mimalloc immediately. Rejected because it increases maintenance before we know whether simpler selection changes exist.

**Implementation:** Trace the dependency graph from `snix-redox/Cargo.toml` into the self-build source bundle, identify who enables `libmimalloc-sys`, and test whether Redox can switch to an equivalent allocator path. Only if that fails do we patch the allocator crate itself.

### 3. Treat behavioral equivalence as the acceptance bar for any allocator change

**Choice:** Any Redox-specific allocator workaround must still produce a self-built `snix` binary that passes the existing focused checks (`snix-compile`, `snix-binary-runs`, `snix-eval-works`) and then the full self-hosting rerun.

**Rationale:** The goal is not just to silence the C compiler. We need a working self-hosted binary and an evidence-backed closeout path for the remaining self-hosting blocker.

**Alternative:** Accept a workaround that only lets the derivation finish. Rejected because it could mask runtime regressions.

**Implementation:** Keep the existing runtime checks in the focused runner and reuse them after any allocator-path change.

## Risks / Trade-offs

- **Allocator selection diverges from upstream** → Keep the divergence Redox-only, document it, and rerun the full self-hosting suite after the focused pass.
- **Vendor patch maintenance burden** → Prefer feature selection first; if patching is required, keep the patch minimal and scoped to the failing Redox atomic assumptions.
- **Focused runner drifts from full-suite reality** → Keep the focused profile derived from `self-hosting.nix` with the same source bundle path and follow up with a full-suite rerun before claiming success.
- **Failure is deeper than allocator choice** → Preserve durable logs and compare each experiment against the current focused baseline so we can distinguish allocator fixes from unrelated regressions.

## Migration Plan

1. Attach the focused `libmimalloc-sys` evidence to this change as the current baseline.
2. Trace and change allocator selection or patch the allocator crate in the self-build inputs.
3. Rerun `nix run .#snix-compile-test -- --verbose` until `FUNC_TEST:snix-compile:PASS` is stable.
4. Rerun `nix run .#self-hosting-test -- --verbose` to confirm the full-suite baseline moves forward.
5. Update OpenSpec evidence, tasks, and AGENTS guidance with the final root cause and resolution.

## Open Questions

- Which crate or feature in the `snix` dependency graph is currently forcing `libmimalloc-sys` into the Redox self-build?
- Does `snix` or one of its dependencies already expose a supported non-mimalloc allocator mode for Redox?
- If a vendor patch is required, is the failing behavior specific to Redox headers, current clang, or mimalloc's `_Atomic` usage assumptions?
- If the allocator path changes, do we need to update both the host package build and the on-image source bundle to keep self-hosted rebuilds consistent?
