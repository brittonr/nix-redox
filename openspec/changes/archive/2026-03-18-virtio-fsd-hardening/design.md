## Context

virtio-fsd is a ~2100-line Redox OS driver that exposes a host directory to the guest via the FUSE protocol over virtio transport. It's the sole data channel for the snix build bridge. The driver has five source files:

- `fuse.rs` (345 lines) — Wire protocol structs and constants
- `transport.rs` (248 lines) — DMA buffer management and virtqueue exchange
- `session.rs` (656 lines) — Typed FUSE operations (lookup, read, write, etc.)
- `scheme.rs` (747 lines) — Redox SchemeSync trait mapping to FUSE ops
- `main.rs` (169 lines) — PCI probe, FUSE_INIT, event loop

The code works for basic file I/O but has blind spots: errors are swallowed, operations are silent, symlinks are unsupported, and large transfers fail hard.

**Constraints:**
- Single-threaded event loop (all `&mut self` on `FuseSession`)
- Two pre-allocated DMA buffers reused for every operation (no per-request allocation)
- Must run in early boot before logd — `eprintln!` for init, `log::*` after scheme registration
- Redox and Linux use different errno values and open flag layouts

## Goals / Non-Goals

**Goals:**
- Preserve real error information across the FUSE ↔ Redox boundary
- Make the driver observable via structured logging
- Support symlinks (required for Nix store paths)
- Handle large I/O without hard failures
- Flush writes before releasing file handles

**Non-Goals:**
- Multi-queue support (only one request queue used today; hiprio queue already set up but unused)
- Rename/hardlink support (not needed for the binary cache use case)
- Extended attributes (xattr) — not used by snix
- Caching or readahead beyond what virtiofsd provides
- Refactoring the build-bridge.nix polling mechanism (separate change)

## Decisions

### 1. Errno translation via lookup table, not arithmetic

FUSE error codes are negative Linux errno values. Linux and Redox share many errno numbers but not all, and Redox defines some differently (e.g., Redox ENOENT = 2, same as Linux; but the Rust constant paths differ). A `match` statement mapping the ~15 common values is clearer and safer than assuming numeric equality.

**Alternative**: Transmit the raw negative value as `Error::new(-fuse_error)`. Rejected because Redox errno constants are defined in `syscall::error` and some may diverge from Linux values in the future.

**Implementation**: Add `fn fuse_error_to_redox(fuse_errno: i32) -> Error` in `scheme.rs`. Every `.map_err(|_| ...)` call in scheme methods gets replaced with `.map_err(|e| fuse_err(e))` where `fuse_err` unwraps the transport error.

### 2. Log at debug level, errors at warn level

Debug-level logs on every entry point gives a complete trace when needed (`RUST_LOG=virtio_fsd=debug`) without noise in normal operation. Warnings on error paths are always visible.

**Alternative**: Info-level for opens/closes, debug for reads/writes. Rejected — opens are too frequent during `snix install` (hundreds of narinfo lookups) and would be noisy at info level.

**Implementation**: Each scheme method gets a `log::debug!` at entry with handle ID + operation-specific args (path, offset, size). Error paths get `log::warn!` with the operation name and translated error.

### 3. Symlink resolution in resolve_path with hop counter

`resolve_path` currently walks path components via FUSE_LOOKUP. Symlink support adds: after each LOOKUP, check if the returned node has `S_IFLNK` mode. If so, call FUSE_READLINK, then restart resolution from the target. A hop counter (max 40, matching Linux `MAXSYMLINKS`) prevents infinite loops.

**Alternative**: Let the host resolve symlinks (virtiofsd with `-o resolve_symlinks`). Rejected because that's a virtiofsd config flag we don't control, and it doesn't help with symlinks created through the scheme.

**Implementation**:
- `FuseSession::readlink(nodeid) -> Result<String>` — new method, sends opcode 5
- `FuseSession::symlink(parent, name, target) -> Result<FuseEntryOut>` — new method, sends opcode 6
- `resolve_path` gains `symlink_hops: u32` parameter, returns `ELOOP` when exceeded
- FUSE_READLINK response is just raw bytes (the target path), no structured body

### 4. Chunk in session layer, transparent to scheme

Chunking belongs in `FuseSession::read` and `FuseSession::write`, not in the scheme. The scheme calls `session.read(nodeid, fh, offset, size)` and gets back data regardless of whether it took 1 or 5 FUSE round-trips.

**Alternative**: Chunk in the scheme layer. Rejected because the session owns the DMA buffers and knows the `max_write` limit — the scheme shouldn't need to know about FUSE transfer constraints.

**Implementation**:
- `read()`: loop with `min(remaining, effective_max)` sized chunks, concatenate results, stop on short read
- `write()`: loop with chunks, advance offset by bytes-written each round, stop on short write
- `effective_max = min(self.max_write as usize, MAX_IO_SIZE)` — respects both negotiated and buffer limits
- Existing callers unchanged

### 5. Flush only writable handles, ignore flush errors

FUSE_FLUSH tells the host to push dirty pages. Only writable file handles have dirty data. Directory handles and read-only handles skip flush. If flush fails (host I/O error), we log and still release — leaking the host file handle is worse than a failed flush.

**Alternative**: Flush all handles. Rejected — unnecessary round-trips for reads and dirs.

**Implementation**:
- `FuseSession::flush(nodeid, fh) -> Result<()>` — new method, opcode 25
- `on_close`: check `handle.writable && !handle.is_dir`, call flush, log-and-ignore errors, then release

## Risks / Trade-offs

**[Symlink resolution adds latency to path lookups]** → Each symlink hop is an extra FUSE_READLINK round-trip. For the Nix store case, symlinks are typically one level deep (e.g., `/nix/store/hash-name` → actual content). The 40-hop limit bounds the worst case. Mitigation: none needed for current workloads.

**[Chunked I/O is synchronous and single-threaded]** → A 10 MiB write becomes 10 sequential FUSE round-trips. This is fine for the build bridge (NARs are typically transferred in bulk before guest access) but would be slow for interactive large-file workloads. Mitigation: acceptable for current use case; multi-queue support would be a separate change.

**[Errno mapping table may miss values]** → New Linux errno values could appear in FUSE responses that aren't in our table. Mitigation: the fallback to `EIO` is conservative and the `log::warn!` will surface it.

**[Flush adds one extra round-trip per writable close]** → Negligible compared to the write operations themselves. The bridge creates files, writes NARs, and closes — one more FUSE op per file is invisible.
