## Context

snix on Redox uses a two-layer build sandbox. Layer 1 (scheme-level) creates a restricted namespace via `mkns`/`setns` that strips access to `display:`, `disk:`, `irq:`, and other schemes. Layer 2 (per-path) interposes a proxy daemon as `file:` in the builder's namespace, filtering filesystem I/O against an allow-list of declared inputs, `$out`, and `$TMPDIR`. The proxy routes permitted reads/writes to the real filesystem through the parent process's namespace.

The infrastructure for both layers exists. `build_proxy/` has ~1300 lines across four files: `allow_list.rs` (path matching, component-boundary enforcement, `..` traversal prevention), `handler.rs` (`SchemeSync` implementation routing `openat`/`read`/`write`/`getdents`/`fstat` through the allow-list), `lifecycle.rs` (proxy thread spawn, event loop, socket shutdown), and `mod.rs` (cross-platform stubs, error types). `sandbox.rs` defines `PROXY_REQUIRED_SCHEMES` (memory/pipe/rand/null/zero, no file) and `setup_proxy_namespace()` which creates the child namespace and starts the proxy. `local_build.rs` tries the proxy first, falls back to scheme-only sandbox, falls back to unsandboxed.

The proxy is disabled for real workloads. `self-hosting-test.nix` sets `sandbox = false` because the proxy hasn't been validated against deep process hierarchies (cargo→rustc→cc→lld) or high-crate-count builds (193-crate snix, 33-crate ripgrep). The `proxy_namespace_test.rs` binary validates kernel mechanisms (mkns without file, register_scheme_to_ns) but doesn't exercise full I/O round-trips through the handler.

## Goals / Non-Goals

**Goals:**
- Validate the proxy against the self-hosting test suite (62 tests, 193-crate snix build, 33-crate ripgrep build)
- Fix handler issues exposed by real builds (concurrent I/O under deep process trees, fd lifecycle across fork/exec chains, directory creation for `$out` subdirectories, symlink resolution edge cases)
- Extend `proxy_namespace_test.rs` with full round-trip I/O tests (write→read, mkdir, getdents, permission denial)
- Enable `sandbox = true` by default in self-hosting-test.nix
- Add targeted proxy regression tests to functional-test.nix

**Non-Goals:**
- Per-hash store path filtering at the scheme level (the allow-list already does prefix matching on full paths — per-hash adds nothing)
- Sandbox escape hardening beyond allow-list + namespace (no seccomp equivalent on Redox, no ptrace sandboxing)
- Proxy support for scheme-internal operations (mmap, ioctl — builders don't use these on file:)
- Performance parity with unsandboxed builds (proxy adds IPC round-trip per syscall; 10-20% overhead acceptable)
- Sandboxing non-snix processes (the proxy is purpose-built for Nix build isolation)

## Decisions

### 1. Fix handler before enabling, not after

**Decision**: Run the self-hosting suite with `sandbox = true` in a separate test target first. Collect failures, fix the handler, iterate. Only flip the default in self-hosting-test.nix after all 62 tests pass with the proxy.

**Rationale**: Enabling first and debugging in-place risks destabilizing the existing test suite. A parallel test target isolates regressions. The handler has known gaps: `openat` doesn't handle `O_CREAT` with missing parent directories (cargo creates nested output dirs), `getdents` may miss entries when the allow-list contains overlapping prefixes, and the `O_ACCMODE` flag translation uses hardcoded Redox values that haven't been tested against all builder flag combinations.

### 2. Thread-safe handler via Mutex, not async

**Decision**: Wrap `BuildFsHandler` in a `Mutex` for the event loop rather than converting to async. The `SchemeSync` trait already requires `&mut self` exclusivity.

**Rationale**: `SchemeSync` processes one request at a time per the Redox scheme protocol. The handler's `HashMap<usize, ProxyHandle>` isn't accessed concurrently — the event loop is single-threaded. The Mutex is only needed for the shutdown path (closing the socket fd from the parent thread while the event loop blocks on `next_request`). An async scheme handler would require a Redox-compatible async runtime, which doesn't exist.

### 3. Translate open flags explicitly, not bitwise

**Decision**: Add a `translate_open_flags()` function that maps Redox open flags to the handler's internal representation, rather than masking individual bits.

**Rationale**: Redox open flags differ from POSIX (`O_RDONLY=0x10000`, `O_CREAT=0x02000000`). The current handler uses `O_ACCMODE` and `O_CREAT` constants from `syscall::flag`, which are already Redox values since the handler runs on Redox. But `O_RDWR` is checked via `O_WRONLY | 0x0001_0000` which is fragile. An explicit translation function documents every flag and catches new flags added by kernel updates.

### 4. Recursive mkdir for $out subdirectories

**Decision**: When `openat` receives `O_CREAT` for a path under `$out` or `$TMPDIR` and parent directories don't exist, create them automatically.

**Rationale**: Cargo creates deep output structures (`$out/lib/rustlib/x86_64-unknown-redox/lib/`). The real filesystem creates intermediate dirs on `open(O_CREAT)` because redoxfs handles it. The proxy must replicate this behavior since it intercepts `file:` before redoxfs sees it. Without recursive mkdir, builds fail with ENOENT on nested output paths.

### 5. Proxy round-trip test in proxy_namespace_test.rs, not unit tests

**Decision**: Extend the existing `proxy_namespace_test.rs` binary (which runs inside the VM) with I/O round-trip tests. Don't add host-side unit tests for the handler event loop.

**Rationale**: The handler's behavior depends on the Redox scheme protocol, kernel namespace isolation, and real filesystem state. Host-side unit tests can validate `AllowList` logic (already done — 25 tests) but can't exercise the scheme socket → handler → real fs → response path. The existing test binary already validates mkns and register_scheme_to_ns; extending it with write→read→verify tests covers the full stack.

## Risks / Trade-offs

- **[IPC overhead]**: Every file operation goes through scheme socket IPC. Cargo builds do thousands of open/read/close cycles. Measured overhead from proxy_namespace_test: ~15μs per round-trip. For 193-crate builds with ~50k file ops, that's ~750ms added to a build that takes minutes. Acceptable.
- **[Single-threaded event loop]**: If a builder forks 4 rustc processes that all do file I/O simultaneously, requests queue at the scheme socket. The kernel serializes scheme requests per-socket anyway, so this matches existing behavior. Risk: a stalled real-fs read blocks all queued requests. Mitigation: set read timeouts on real file operations.
- **[Missing flag combinations]**: The handler may not handle all `openat` flag combinations that cargo/rustc/lld use. The fix-as-you-go approach (run tests, fix failures, iterate) works because the self-hosting suite exercises the exact flag combinations real builds produce.
- **[Symlink resolution across allow-list boundaries]**: Store paths contain symlinks (e.g., `libfoo.so → libfoo.so.1.0`). The handler resolves symlinks via `fs::canonicalize()` which returns `file:/path` on Redox — the `file:` prefix strip is in place but untested under load. Risk: a symlink chain crossing from one store path to another could bypass the allow-list. Mitigation: check both the requested path AND the resolved path against the allow-list (already implemented in `check_with_symlink_resolution`).
- **[Proxy death during build]**: If the proxy thread panics, the builder's file operations get ENOENT (no file: scheme). The build fails with an opaque error. Mitigation: `panic::catch_unwind` in the event loop thread (already implemented), log the panic with context, and `local_build.rs` checks proxy health before reporting build failure.
