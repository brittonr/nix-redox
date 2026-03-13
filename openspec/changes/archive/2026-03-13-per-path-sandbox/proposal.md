## Why

Snix builds currently sandbox at the scheme level — a builder either sees all of `file:` or none of it. A builder that needs filesystem I/O gets access to the entire filesystem: `/home`, `/etc`, other users' data, unrelated store paths. Real Nix on Linux bind-mounts only declared inputs into the build environment, making builds hermetic. Without per-path filtering, snix builds can accidentally depend on undeclared inputs, producing unreproducible results, and any builder can read sensitive host files.

## What Changes

- A new **proxy scheme daemon** (`buildfs`) that implements the `file:` scheme interface but restricts access to an allow-list of paths. The proxy runs in-process (spawned thread) during each build, forwarding permitted I/O to the real `file:` scheme in the parent's namespace.
- The build sandbox setup registers the proxy as `file` in the child's namespace using `register_scheme_to_ns(child_ns_fd, "file", ...)`, so builders transparently use it without code changes.
- The allow-list includes: the derivation's `$out` directory (read+write), `$TMPDIR` (read+write), and resolved input store paths from `input_derivations` and `input_sources` (read-only). Everything else returns `EACCES` or `ENOENT`.
- The existing scheme-level sandbox (`mkns` with `[file, memory, pipe, ...]`) is replaced: the child namespace gets `[memory, pipe, rand, null, zero]` plus the proxy registered as `file`. FOD builds also get `net`.
- Graceful fallback: if proxy setup fails or the kernel doesn't support `register_scheme_to_ns`, builds run unsandboxed with a warning (preserving current behavior).

## Capabilities

### New Capabilities
- `build-filesystem-proxy`: The proxy scheme daemon that interposes on `file:` for build processes, implementing path-based access control with an allow-list derived from derivation inputs.

### Modified Capabilities
- `namespace-sandboxing`: The sandbox setup changes from including `file` in the scheme list to excluding it and registering the proxy as `file` in the child namespace instead. Fallback behavior and FOD network access are preserved.

## Impact

- **`snix-redox/src/sandbox.rs`**: Major changes — new proxy daemon code, scheme handler implementation, allow-list logic, lifecycle management (spawn/shutdown).
- **`snix-redox/src/local_build.rs`**: Modified build flow — spawn proxy thread before fork, pass child namespace fd, shut down proxy after build.
- **`snix-redox/Cargo.toml`**: No new dependencies — `redox-scheme`, `libredox`, and `redox_syscall` are already present for stored/profiled.
- **Performance**: Every file operation in the builder becomes an IPC roundtrip through the scheme socket. Builds will be slower. Mitigation options (read-ahead, caching) can be explored in follow-up work.
- **Test coverage**: Existing sandbox tests need updating. New tests for allow-list enforcement, proxy lifecycle, and fallback behavior. VM tests to verify builders can't read undeclared paths.
- **Existing scheme daemons**: `stored` and `profiled` are unaffected — they run in the system namespace, not the per-build proxy namespace.
