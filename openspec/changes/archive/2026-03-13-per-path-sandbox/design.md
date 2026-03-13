## Context

Snix builds on Redox OS use `mkns`/`setns` to restrict which schemes a builder process can access. This blocks `display:`, `disk:`, `audio:`, etc., but the `file:` scheme is all-or-nothing — a builder that needs to read `/nix/store/dep-1.0/lib/libfoo.a` also gets access to `/home/user/.ssh/id_rsa` and every other file on the system.

Redox has no `chroot`, `pivot_root`, bind-mount namespaces, or any other mechanism to restrict paths within a scheme. The only isolation primitive is scheme-level namespace filtering. However, Redox's scheme architecture gives us something Linux doesn't: any userspace process can register itself as a scheme provider. Combined with `register_scheme_to_ns(ns_fd, name, cap_fd)` — which registers a scheme into a specific namespace fd — we can interpose a filtering proxy between the builder and the real filesystem.

Existing scheme daemons in the codebase (`stored`, `profiled`, `virtio-fsd`) demonstrate the pattern: implement `SchemeSync`, handle open/read/write/getdents/fstat, register with the kernel, and run an event loop. The proxy reuses this pattern but with a twist: it registers as `file` (not a custom name) in a child namespace, and it runs per-build (not system-wide).

## Goals / Non-Goals

**Goals:**
- Restrict builder filesystem access to declared inputs, `$out`, and `$TMPDIR`
- Transparent to builders — programs call `open("/nix/store/...")` and it works without changes
- Graceful fallback to unsandboxed builds if the mechanism fails
- Reuse existing `redox-scheme` infrastructure (same crate as stored/profiled)

**Non-Goals:**
- Per-path filtering within `store:` scheme (stored handles this separately; future work)
- Syscall filtering / seccomp equivalent (Redox doesn't have this)
- Write isolation for `$out` (preventing writes to other outputs in multi-output derivations) — phase 2
- Performance optimization (read-ahead, buffer caching, zero-copy) — follow-up work
- Network path filtering (FODs get full `net:` access, same as today)
- Filtering within `memory:`, `pipe:`, `rand:`, `null:`, `zero:` (these are stateless/safe)

## Decisions

### Decision 1: In-process proxy thread (not a separate daemon process)

The proxy runs as a thread within the snix process, not a separate binary.

**Rationale:** Stored and profiled are system-wide daemons that persist across boots. The build proxy is ephemeral — it exists only for the duration of one build. Spawning a separate process adds fork/exec overhead, signal handling complexity, and cleanup risk (orphan processes if snix crashes). A thread shares the parent's namespace (which has real `file:` access), can be joined on build completion, and dies automatically if the parent crashes.

**Alternative considered:** Separate process. Rejected because it needs IPC for the allow-list configuration, process lifecycle management, and doesn't gain us anything (the proxy is not untrusted code).

### Decision 2: Register proxy as `file` in child namespace via `register_scheme_to_ns`

The sequence:
1. `mkns([memory, pipe, rand, null, zero])` → `child_ns_fd` (no `file` in the list)
2. `Socket::create()` → scheme socket
3. `register_scheme_to_ns(child_ns_fd, "file", cap_fd)` → proxy becomes `file:` for the child
4. `fork()` child → `pre_exec: setns(child_ns_fd)` → `exec(builder)`
5. Proxy thread runs event loop on the scheme socket
6. Builder's `open("file:/path")` → routed to proxy → proxy checks allow-list → proxy does real `open("file:/path")` in parent namespace → returns result

**Rationale:** This is the only way to make per-path filtering transparent. The builder, and everything it runs (bash, cargo, rustc, lld), all use `file:` implicitly. Registering the proxy under a different name (`buildfs:`) would require patching every program.

**Key question resolved:** `register_scheme_to_ns` takes an explicit `ns_fd` parameter, meaning the parent can register a scheme into a namespace it created but hasn't switched to. The parent retains its own namespace with real `file:` access.

### Decision 3: Allow-list structure

```
AllowList {
    // Read-only paths (store inputs)
    read_only: HashSet<PathBuf>,   // e.g., /nix/store/abc-dep-1.0

    // Read-write paths (output + tmpdir)
    read_write: HashSet<PathBuf>,  // e.g., /nix/store/out-hash-name, /tmp/snix-build-42

    // Prefix matching: /nix/store/abc-dep-1.0/lib/foo.so matches
    // the read_only entry /nix/store/abc-dep-1.0
}
```

Paths are matched by prefix. Opening `/nix/store/abc-dep-1.0/lib/foo.so` succeeds because `/nix/store/abc-dep-1.0` is in `read_only`. Opening `/nix/store/xyz-other/bin/bar` fails because no prefix matches.

**Rationale:** Prefix matching is simple, fast (iterate allow-list, check `starts_with`), and matches how Nix stores paths — everything under a store path hash is one logical unit. No need for glob patterns or regex.

### Decision 4: Proxy implements a minimal SchemeSync subset

The proxy must handle the operations builders actually use:
- `openat` — path resolution + allow-list check
- `read` — forward to real fd
- `write` — forward to real fd (only for read-write paths)
- `fstat` — forward to real fd
- `fsize` — forward to real fd
- `getdents` — directory listing, filtered to show only allowed entries
- `fpath` — return the scheme-relative path
- `on_close` — close the real fd

Not implemented (return `ENOSYS`):
- `rename`, `unlink` — only on read-write paths; implement in phase 2
- `fchmod`, `fchown` — Redox doesn't enforce Unix permissions strongly
- `mmap` — `memory:` scheme handles anonymous mappings; file-backed mmap not common in builders

**Rationale:** Start with the minimum viable set. Cargo/rustc builds primarily open files for reading (rlibs, sources), write to `$out`, and stat paths. Directory listing is needed for `ls`, `find`, and build script path discovery.

### Decision 5: Proxy lifetime tied to Command execution

```
fn build_derivation_inner(...) {
    // 1. Build allow-list from derivation
    let allow_list = build_allow_list(drv, known_paths, &output_dir, &build_dir);

    // 2. Create child namespace (WITHOUT file:)
    let child_ns_fd = mkns([memory, pipe, rand, null, zero]);

    // 3. Start proxy thread
    let proxy = BuildFsProxy::start(child_ns_fd, allow_list)?;

    // 4. Fork + exec builder (child calls setns(child_ns_fd))
    let status = cmd.status()?;  // blocks until builder exits

    // 5. Shut down proxy
    proxy.shutdown();
}
```

The proxy thread starts before fork and stops after the builder exits. The scheme socket is closed, which causes the proxy's event loop to terminate.

**Rationale:** Clean lifecycle — no orphan threads, no dangling scheme registrations. The socket close acts as the shutdown signal (same pattern as stored/profiled: `socket.next_request()` returns `None`).

### Decision 6: Real file I/O via parent namespace handles

The proxy thread runs in the parent's namespace (threads share the process namespace). When the proxy needs to open a real file for forwarding, it uses standard `std::fs::File::open()` — this goes through the parent's `file:` scheme, which is the real filesystem.

The proxy maintains a handle table mapping child-visible handle IDs to real file descriptors:

```
handles: HashMap<usize, ProxyHandle>

enum ProxyHandle {
    File { real_fd: File, path: PathBuf, writable: bool },
    Dir { real_path: PathBuf, scheme_path: String },
}
```

**Rationale:** No special plumbing needed. The parent thread has full filesystem access. The child's `file:` requests arrive on the scheme socket; the proxy resolves them against the allow-list, opens the real file, and proxies the data.

## Risks / Trade-offs

**[Performance: IPC overhead per file operation]** → Every `open`, `read`, `write`, `stat` in the builder becomes a scheme request → kernel IPC → proxy thread → real file I/O → response. For a cargo build touching thousands of files, this could add significant latency. → *Mitigation:* Measure first. The proxy can buffer reads (read full file on open, serve from memory). If too slow, implement read-ahead or consider kernel-side ACL support as a long-term path.

**[Complexity: full SchemeSync implementation]** → The proxy must correctly implement file operations. Bugs here break all builds. → *Mitigation:* Start with pass-through (no filtering) to validate correctness, then add allow-list. Extensive unit tests. The existing stored/profiled/virtio-fsd provide reference implementations for every trait method.

**[Directory listings must be filtered]** → `getdents` on `/nix/store/` should only show allowed entries. But the real directory has all entries. The proxy must filter. → *Mitigation:* Read real directory, filter entries against allow-list, return filtered list. Simple but adds complexity to `getdents`.

**[Symlinks crossing sandbox boundaries]** → A symlink in `/nix/store/dep-1.0/lib/libfoo.so → ../dep-2.0/lib/libfoo.so` where `dep-2.0` is not in the allow-list. Should the proxy follow the symlink and check the target? → *Mitigation:* Phase 1: resolve symlinks and check the target path against the allow-list. If the target is outside the sandbox, return `EACCES`. This matches Nix on Linux behavior (bind-mounts don't follow symlinks outside the mount).

**[Thread safety with fork()]** → Redox's `fork()` and threads don't always play well together (relibc Mutex is non-reentrant). The proxy thread must be running before fork and must not hold any locks that the child would inherit. → *Mitigation:* The proxy thread only touches its own data (handle table, allow-list). No shared mutexes with the main thread. Communication is through the scheme socket (kernel-mediated).

**[register_scheme_to_ns might not accept "file" as a name]** → The kernel might reject registering a userspace scheme with the name `file` since that's a kernel-managed scheme (redoxfs). → *Mitigation:* This is the first thing to validate with a prototype. If rejected, fall back to a kernel patch that adds ACL support to the existing `file:` scheme, or find an alternative registration path.

## Open Questions

1. **Can `register_scheme_to_ns` register a scheme named `file` in a child namespace?** The kernel's `file:` scheme is provided by redoxfs. Can a userspace scheme shadow it in a child namespace? This determines whether Approach A works at all. Needs a prototype test.

2. **What happens to `/dev/null`, `/dev/zero`, `/dev/urandom` paths?** These are symlinks to `/scheme/null`, `/scheme/zero`, `/scheme/rand` respectively. If a builder opens `/dev/null` via `file:`, the proxy sees it. Should the proxy follow the symlink resolution or does the kernel handle it before the scheme dispatch?

3. **Does the builder's `exec()` itself need `file:` access?** The `pre_exec` closure calls `setns(child_ns_fd)` and then the kernel does `exec(builder_path)`. Does `exec` resolve the builder path through the `file:` scheme? If so, the proxy must be running and handling requests during `exec()` itself.

4. **Read performance for large files (rlibs, shared objects)?** Rustc reads rlibs that can be 10-50MB. Each `read()` call through the proxy is an IPC roundtrip. What's the maximum buffer size per scheme read request? Can we serve the whole file in fewer round-trips?
