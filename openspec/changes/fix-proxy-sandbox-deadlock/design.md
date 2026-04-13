## Context

The snix build sandbox was designed around a child namespace that sees a proxy `file:` scheme instead of the real filesystem. That design is already specified and partially implemented, but it is disabled because the proxy deadlocks when it forwards an allowed open to redoxfs. The observed failure is specific: the proxy process owns a scheme socket and then issues `SYS_OPENAT` through a pre-opened root fd, and the kernel blocks that I/O path. The current scheme-only sandbox keeps build isolation by hiding sensitive schemes, but it cannot enforce per-path allow-lists.

## Goals / Non-Goals

**Goals:**
- Restore the intended per-path proxy sandbox for normal `snix build` execution.
- Fix the kernel behavior narrowly enough that proxy forwarding works without opening unrelated scheme-I/O escape hatches.
- Leave a deterministic reproducer and regression suite behind so the deadlock does not return unnoticed.

**Non-Goals:**
- Redesign the entire Redox scheme model.
- Remove the scheme-only fallback for older kernels or unsupported environments.
- Expand sandbox policy beyond the already-planned allow-list semantics.

## Decisions

### 1. Fix the kernel path narrowly around pre-opened real filesystem descriptors

**Choice:** Allow a process that owns a scheme socket to issue filesystem I/O through a pre-opened root fd when that fd targets the real filesystem instance used for proxy forwarding.

**Rationale:** The deadlock comes from a narrow and reproducible forwarding path. A targeted exception is safer than weakening the general scheme blocking policy globally.

**Alternative considered:** Move the proxy to a separate helper process. Rejected for now because it adds new lifetime, namespace, and handle-passing complexity before proving the kernel rule itself is the blocker.

### 2. Detect capability at runtime and keep an explicit fallback

**Choice:** Re-enable the proxy path behind a runtime capability probe or concrete kernel-version behavior check, and keep the existing scheme-only fallback with a warning when the safe forwarding path is unavailable.

**Rationale:** The repo already supports mixed kernel states during development. Runtime detection lets the same tree work before and after the kernel fix lands.

**Alternative considered:** Hard flip back to proxy mode unconditionally. Rejected because it would re-break current test images until every environment picks up the fixed kernel.

### 3. Add a focused reproducer before re-enabling the full self-hosting path

**Choice:** Add a small reproducer that owns a scheme socket and then exercises forwarded `openat`/read/write through the proxy path, then keep the larger sandbox suite as the second gate.

**Rationale:** The self-hosting suite is too large and too slow to diagnose kernel regressions by itself. A focused reproducer gives a fast pass/fail signal and isolates the exact failure mode.

**Alternative considered:** Rely only on `snix-sandbox-test`. Rejected because it gives weaker diagnostics when the kernel behavior regresses.

## Risks / Trade-offs

- **Kernel exception too broad** → Keep the allowed path tied to pre-opened real-fs descriptors used by the proxy and cover it with negative tests.
- **Mixed-kernel environments** → Keep scheme-only fallback and surface a clear warning when proxy mode is unavailable.
- **Regression only appears under heavy cargo workloads** → Keep both the focused reproducer and the sandbox/self-hosting suites in the validation plan.

## Migration Plan

1. Land the focused reproducer and capture current failure output.
2. Implement the narrow kernel fix and verify the reproducer passes.
3. Re-enable proxy mode in snix behind runtime capability detection.
4. Rebaseline `snix-sandbox-test` and self-hosting evidence with proxy mode active.

## Open Questions

- Whether the runtime gate should be a direct probe, a kernel feature bit, or a versioned behavior check.
- Whether any other scheme types besides redoxfs need the same safe forwarding exception.
