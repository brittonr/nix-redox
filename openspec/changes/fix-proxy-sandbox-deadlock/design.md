## Context

The snix build sandbox wants a proxy `file:` scheme in the builder namespace so filesystem access is filtered to declared inputs, `$out`, and `$TMPDIR`. That proxy already existed, but it was disabled after builds hung on the first forwarded redoxfs open.

The old explanation said the kernel blocks all `file:` I/O from any process that owns a scheme socket. That does not match the rest of this tree: `stored` and `profiled` own scheme sockets and still use a pre-opened root fd successfully through `FileIoWorker`. The failing difference is that `build_proxy` tried to perform real redoxfs I/O on the same thread that was currently servicing a userspace `file:` request.

## Goals / Non-Goals

**Goals**
- Restore the per-path proxy as the default sandbox path.
- Keep the proxy event loop free of nested redoxfs syscalls.
- Leave focused regression coverage and workload validation behind.

**Non-Goals**
- Redesign the whole Redox scheme model.
- Remove the scheme-only fallback.
- Add new sandbox policy beyond the existing allow-list semantics.

## Decisions

### 1. Use a dedicated real-filesystem worker thread

**Choice:** Forward every real redoxfs and device operation from the proxy handler to a background worker thread.

**Rationale:** This is the pattern that already works for `stored` and `profiled`. The worker thread owns the pre-opened root/device handles and can block in real filesystem syscalls without stalling the scheme event loop.

### 2. Re-enable proxy mode directly, keep runtime fallback on setup failure

**Choice:** Make proxy mode the default again. If `setup_proxy_namespace()` fails, log a warning and fall back to the scheme-only sandbox.

**Rationale:** No kernel feature probe is needed once the deadlock is fixed in userspace. Mixed environments still need graceful fallback for plain setup failures.

### 3. Keep focused regression plus real cargo workload validation

**Choice:** Extend `proxy_namespace_test` with a worker-cycle regression and require a sandbox VM run plus one self-hosting-oriented validation run.

**Rationale:** The focused test catches the original failure shape quickly; the workload run proves cargo subprocess trees survive the proxy.

## Risks / Trade-offs

- **More IPC per filesystem op** -> acceptable; correctness matters more than micro-optimizing the proxy first.
- **Worker thread lifetime leaks** -> keep it owned by `BuildFsHandler` so dropping the handler shuts the worker down.
- **Proxy setup can still fail for unrelated reasons** -> keep the explicit warning + scheme-only fallback path.

## Migration Plan

1. Add worker-backed proxy forwarding and focused regression coverage.
2. Re-enable proxy mode in `local_build.rs`.
3. Re-run sandbox and self-hosting validation with proxy mode active.
4. Update docs/specs to describe the worker-thread fix.
