## Context

Redox OS has a unique microkernel architecture where all I/O goes through **schemes** — userspace daemons that register a URL namespace with the kernel. When a process calls `open("/scheme/foo/bar")`, the kernel routes the request to the `foo` scheme daemon, which handles it like a FUSE filesystem but with Redox's native syscall interface (`SYS_OPEN`, `SYS_READ`, `SYS_WRITE`, `SYS_CLOSE`, `SYS_FSTAT`). Existing examples in this repo:

- **`virtio-fsd`** (`nix/pkgs/system/virtio-fsd/src/`): A scheme daemon that bridges FUSE-over-virtqueue to the host filesystem. Handles `open`, `read`, `write`, `stat`, `readdir` by translating Redox syscalls to FUSE opcodes sent over a virtio queue.
- **`redoxfs`**: The filesystem driver, itself a scheme daemon serving the `file:` scheme.
- **Drivers**: `e1000d`, `virtio-netd`, `pcid` — all scheme daemons.

The scheme daemon pattern is well-established: register with the kernel via `open("/scheme/{name}", O_CREAT)`, enter a request loop reading `Packet` structs, dispatch by syscall number, write responses back. The `redox_scheme` crate provides the `SchemeBlockMut` trait with method-per-syscall dispatch.

snix currently uses:
- `/nix/store/` as a flat filesystem directory (no scheme)
- Symlink farms in `/nix/var/snix/profiles/default/bin/` (no scheme)
- Unsandboxed `std::process::Command` for builders (no namespace restriction)
- `PathInfoDb` at `/nix/var/snix/pathinfo/` as JSON files

The existing `virtio-fsd` implementation is the closest reference for how to build a new scheme daemon. It handles the full lifecycle: open/read/write/close/stat/readdir, file descriptor tracking with a handle table, and proper error propagation via `SYS_ERROR`.

## Goals / Non-Goals

**Goals:**
- `stored` daemon serves store paths lazily — first access triggers extraction, subsequent accesses read from disk
- `profiled` daemon presents union views of installed packages — adding/removing a package is an in-memory table update + manifest write
- Builders run under restricted namespaces — can only access declared inputs and their output directory
- Everything falls back gracefully when daemons aren't running (direct filesystem I/O, no sandboxing)
- Wire into the module system so profiles can opt into scheme-based management

**Non-Goals:**
- Content-addressed storage (CAS with BLAKE3 dedup) — future change, requires store path model changes
- Remote cache integration inside `stored` (lazy fetch from HTTP) — first version serves only locally-extracted paths; remote fetch is a follow-up
- Multi-user store isolation — single-user Redox for now
- Formal verification of the scheme daemons — future change
- Replacing the existing `/nix/store/` filesystem layout — schemes serve as an overlay, not a replacement

## Decisions

### 1. Scheme daemons as separate binaries, not threads in snix

**Decision**: `stored` and `profiled` are separate binaries (`/bin/stored`, `/bin/profiled`) started by init, not background threads inside the `snix` CLI.

**Rationale**: Redox scheme daemons must be long-running processes that register with the kernel at startup. The `snix` CLI is a short-lived process — it runs a command and exits. A daemon that lives inside `snix` would need `snix` to run perpetually, which conflicts with its CLI model. Separate binaries follow the Redox pattern (every driver/daemon is its own process) and can be managed by init scripts. They also crash-isolate: a bug in `stored` doesn't take down `profiled`.

**Alternative considered**: Threads inside `snix daemon` subcommand. Rejected — Redox scheme registration is per-process (the kernel associates the scheme with a file descriptor owned by the process), so separate processes are the natural fit.

### 2. Lazy extraction on first access, not on install

**Decision**: `snix install` via the store scheme registers the package in PathInfoDb and the profile mapping but does NOT extract the NAR. The first `open()` call through the `store:` scheme triggers extraction.

**Rationale**: Most packages contain many files but the user only accesses a few (typically `bin/`). Extracting everything upfront wastes time and disk space. Lazy extraction means `snix install ripgrep` is near-instant — it just updates metadata. The first `rg --help` triggers extraction of the ripgrep store path. This also enables pre-populating the install manifest with many packages (like a NixOS profile) without paying the extraction cost for packages the user never runs.

**Trade-off**: First access is slower (must decompress + extract). Mitigated by extracting the entire NAR on first access to any file within the store path (not per-file extraction, which would require NAR random access). After first extraction, all subsequent accesses are filesystem-speed.

**Alternative considered**: Per-file lazy extraction using NAR seeking. Rejected — NAR is a sequential format with no index, so random access would require scanning from the start. A NAR index (like `nix-nar-listing`) could enable this later.

### 3. Profile scheme uses a JSON mapping table, not a database

**Decision**: `profiled` maintains an in-memory `BTreeMap<String, Vec<ProfileEntry>>` mapping profile names to lists of (package name, store path) pairs. Persisted as JSON to `/nix/var/snix/profiles/{name}/mapping.json`.

**Rationale**: The profile mapping is small (tens to hundreds of entries), read-heavy (every `open()` through the scheme does a lookup), and rarely written (only on install/remove). An in-memory BTreeMap with occasional JSON serialization is simpler and faster than SQLite or any database. The existing `ProfileManifest` is already JSON — this extends the same pattern.

**Alternative considered**: SQLite via rusqlite. Rejected — adds a C dependency (or pure-Rust reimplementation), overkill for a small mapping table.

### 4. Namespace restriction via Redox's `setns` or `open("/scheme/", O_CREAT)` per-child

**Decision**: Before spawning a builder in `local_build.rs`, create a restricted namespace for the child process that only includes: the `store:` scheme (for reading inputs), the `file:` scheme (for the output directory and /tmp), and optionally `net:` (for FOD derivations that need network access). All other schemes are denied.

**Rationale**: This is Redox's native sandboxing mechanism. The kernel enforces scheme visibility per-process — a process that can't see a scheme simply gets `ENOENT` when trying to open paths in it. No userspace enforcement needed, no race conditions, no escape hatches. This is equivalent to Linux namespaces + seccomp but with a single mechanism.

**Implementation detail**: Redox's namespace mechanism works through the `SYS_SETNS` syscall or by manipulating the process's namespace table. The exact API depends on the Redox kernel version. We'll use the `redox_syscall` crate's namespace functions. If the syscall isn't available (older kernel), fall back to unsandboxed execution with a warning.

**Alternative considered**: Running builders in a separate `namespace:` scheme that restricts visibility. Rejected — `setns` per-child is more direct and doesn't require an intermediate daemon.

### 5. Fallback-first architecture: schemes are optional overlays

**Decision**: All scheme-based functionality is optional. `snix install` checks if `stored` is running (by trying to open `store:`) and falls back to direct filesystem extraction if it's not. `profiled` similarly falls back to symlink farms. Builders fall back to unsandboxed execution if namespace syscalls fail.

**Rationale**: This allows incremental adoption. Users can run the current snix without any daemons and get exactly the behavior they have today. Enabling the daemons (via init scripts or module system options) adds the new capabilities without breaking anything. It also means the test infrastructure doesn't need to change — existing tests work as-is, new tests verify the scheme-based paths.

**Alternative considered**: Hard requirement on scheme daemons. Rejected — breaks existing workflows and makes development harder (can't test without running daemons).

### 6. stored serves the full /nix/store/ namespace

**Decision**: `stored` registers as the `store` scheme and serves all paths under `/nix/store/`. A request for `store:abc...-ripgrep/bin/rg` maps to `/nix/store/abc...-ripgrep/bin/rg` on the filesystem (after lazy extraction if needed).

**Rationale**: The 1:1 mapping between scheme paths and filesystem paths keeps things simple and debuggable. The filesystem is the source of truth for extracted content; the scheme daemon is a transparent overlay that adds lazy extraction. Tools that bypass the scheme and access `/nix/store/` directly continue to work (though they don't get lazy extraction).

**Alternative considered**: Content-addressed scheme where paths are BLAKE3 hashes. Rejected for this change — requires a different store model. CAS is a natural follow-up once the scheme infrastructure is in place.

## Risks / Trade-offs

- **[Redox namespace API instability]**: The `setns` / namespace manipulation API may change between Redox kernel versions. → Mitigation: Feature-gate behind a `sandbox` cargo feature. Fall back to unsandboxed if the syscall returns ENOSYS.
- **[Scheme daemon crashes]**: If `stored` crashes, `open("store:...")` calls fail. → Mitigation: Init can restart it. Extracted paths remain on the filesystem and are accessible directly via `/nix/store/`. The daemon restores its handle table from PathInfoDb on restart.
- **[Lazy extraction latency]**: First access to a package blocks until the full NAR is extracted. For large packages (rustc, llvm), this could be 10+ seconds. → Mitigation: `snix install --eager` flag for explicit upfront extraction. System packages in the profile are pre-extracted during image build.
- **[Handle table memory]**: `stored` keeps open file descriptors in memory. Many concurrent accesses could exhaust file descriptors. → Mitigation: LRU eviction of idle handles. Redox's per-process fd limit is configurable.
- **[Scheme registration ordering]**: `stored` must be running before any process tries `open("store:...")`. → Mitigation: Init starts `stored` early (before login shell). The `SYS_OPEN` call blocks until the scheme is registered if `O_NONBLOCK` is not set (depends on kernel behavior — verify).
- **[Testing complexity]**: Scheme daemons require a running Redox environment to test. Unit tests for the mapping/extraction logic can run on Linux; scheme protocol handling needs VM tests. → Mitigation: Separate the core logic (extraction, mapping, PathInfoDb) from the scheme protocol layer. Unit test the logic, VM test the protocol.
