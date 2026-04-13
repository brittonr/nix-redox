## Why

The strongest technical caveat in Redox self-hosting today is that the per-path snix sandbox is disabled. The intended proxy sandbox deadlocks on the first forwarded `file:` request because the proxy thread owns a scheme socket while trying to access redoxfs through a pre-opened root fd. Until that path works, sandboxed builds are real but weaker than intended.

## What Changes

- Add a minimal kernel-safe path for proxy threads to forward filesystem I/O through a pre-opened real root fd without deadlocking.
- Add a focused reproducer and regression test for the scheme-socket-owner + `SYS_OPENAT(root_fd, ...)` case.
- Re-enable the per-path proxy sandbox in `snix-redox` on kernels that support the safe path, while keeping explicit fallback behavior for unsupported kernels.
- Rebaseline sandbox validation with focused proxy tests and self-hosting runs that exercise real cargo build workloads.

## Capabilities

### New Capabilities
- `proxy-kernel-io-safety`: Let the kernel and snix proxy cooperate so allow-listed per-path sandboxing works without deadlocking and stays covered by regression tests.

### Modified Capabilities

None.

## Impact

- **Kernel**: Redox scheme / file I/O path that currently blocks proxy forwarding from scheme-socket-owning processes.
- **snix**: `snix-redox/src/local_build.rs`, `snix-redox/src/build_proxy/`, namespace setup, runtime capability detection.
- **Validation**: focused proxy reproducer, `snix-sandbox-test`, and self-hosting baselines.
- **Docs**: AGENTS/open evidence should stop treating the proxy as permanently disabled once the kernel path is fixed.
