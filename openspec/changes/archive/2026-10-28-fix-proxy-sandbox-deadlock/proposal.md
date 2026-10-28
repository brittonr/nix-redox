## Why

The per-path snix sandbox had been rolled back to scheme-only fallback because the build proxy hung on its first forwarded real-filesystem request. The old theory blamed process-wide scheme-socket ownership in the kernel. That turned out to be too broad: `stored` and `profiled` already prove that a scheme-owning process can do root-fd filesystem I/O from a separate worker thread. The real failure shape is narrower: the proxy event-loop thread cannot block inside nested redoxfs calls while it is servicing another userspace `file:` request.

## What Changes

- Add a focused reproducer in `proxy_namespace_test` for repeated worker-backed proxy forwarding.
- Move all real redoxfs and `/dev/*` I/O out of the proxy scheme thread into a dedicated worker thread.
- Re-enable the per-path proxy sandbox as the default in `local_build.rs`.
- Keep explicit warning + scheme-only fallback if proxy setup fails.
- Refresh sandbox validation and docs so they describe the worker-thread fix, not the old kernel-blocking theory.

## Capabilities

### New Capabilities
- `proxy-kernel-io-safety`: Let the build proxy forward allow-listed filesystem operations safely by keeping real redoxfs I/O off the scheme event-loop thread.

## Impact

- **snix**: `snix-redox/src/build_proxy/`, `snix-redox/src/local_build.rs`, `snix-redox/src/sandbox.rs`
- **Validation**: `snix-redox/tests/redox/proxy_namespace_test.rs`, `nix/redox-system/profiles/snix-sandbox-test.nix`, VM validation runs
- **Docs**: AGENTS, OpenSpec notes, sandbox docs
