## Context

Four scheme daemons serve the Nix store/profile/build/virtio-fs subsystems on Redox. They were written incrementally as features were added. The build_proxy was the last written and introduced the `root_fd` pattern for bypassing initnsmgr. The FileIoWorker (used by stored/profiled) predates that pattern and still uses `std::fs::*` which routes through the namespace.

Upstream Redox daemons (randd, nulld, etc.) follow a consistent discipline: wrapping handle IDs, entering null namespace after init, implementing fevent. Our daemons diverged on all three.

## Goals / Non-Goals

**Goals:**
- Match upstream Redox daemon patterns for handle IDs, null namespace, and fevent
- Bound the FileIoWorker file descriptor cache so long-running daemons don't leak memory
- Keep all existing tests passing — no behavioral change for callers

**Non-Goals:**
- Rewriting the scheme handler architecture (it works well)
- Adding async/event-driven I/O to stored/profiled (blocking model is fine for our use case)
- Implementing full LRU with access tracking — a simple max-size eviction is sufficient

## Decisions

### 1. Handle ID allocation: wrapping with collision check

**Decision**: Replace `AtomicUsize::fetch_add(1, Relaxed)` with a helper that wraps at `usize::MAX - 4096` and checks the handle map for collisions before returning.

**Rationale**: Matches randd's pattern exactly. The upper 4096 values are reserved by the kernel for error codes. Although 2^64 wraps are practically impossible, collision detection is needed once wrapping is added — a wrapped counter could land on an in-use ID.

**Alternative considered**: Just add `checked_add` with panic — rejected because it crashes the daemon instead of gracefully wrapping. randd's `Wrapping` + loop approach is strictly better.

**Implementation**: Shared helper function in each handles module (not a separate crate — the pattern is 8 lines). Per-instance counter, not atomic, since all scheme handlers are single-threaded (`&mut self`).

### 2. FileIoWorker root_fd bypass for null namespace

**Decision**: Add an optional `root_fd: Option<usize>` to FileIoWorker. When set (Redox), the worker thread uses `SYS_OPENAT(root_fd, path, O_RDONLY)` + `File::from_raw_fd()` instead of `std::fs::File::open()`. When None (tests/Linux), falls back to `std::fs` as today.

**Rationale**: This is the exact pattern build_proxy already uses successfully. The raw fd points directly to redoxfs through the kernel, bypassing initnsmgr. After `setrens(0, 0)`, `std::fs` operations fail (namespace is null), but `SYS_OPENAT(root_fd, ...)` continues working because the fd was opened before setrens.

**Sequence**:
1. Create daemon (spawns FileIoWorker — still has namespace access)
2. Pre-open `/` to get root_fd
3. Pass root_fd to FileIoWorker
4. Register scheme
5. Call `setrens(0, 0)`
6. Enter event loop

The worker thread's `std::fs` calls are replaced with raw syscalls before setrens is called, so no races.

**Alternative considered**: Separate process for file I/O — rejected because the thread-based worker already handles initnsmgr deadlock avoidance correctly and is simpler to manage.

### 3. fevent: return EVENT_READ for readable handles

**Decision**: Add `fevent` override to stored, profiled, and build_proxy. Return `EVENT_READ` for file and directory handles. Return `EVENT_WRITE` for control handles. Return `EVENT_READ | EVENT_WRITE` for build_proxy writable file handles.

**Rationale**: Matches randd (returns `EVENT_READ`) and virtio-fsd (returns `EVENT_READ`, adds `EVENT_WRITE` for writable handles). The stored/profiled schemes are read-only (except .control), so `EVENT_READ` is correct for file/dir handles.

### 4. FileIoWorker cache eviction: cap at 64 entries

**Decision**: When the `BTreeMap<PathBuf, fs::File>` exceeds 64 entries, remove the first (lexicographically lowest) entry before inserting a new one. Not true LRU — just a bounded map.

**Rationale**: 64 open file descriptors is generous for the cached-read pattern. The worker already pre-loads file content into `Vec<u8>` on the scheme handler side, so the worker's fd cache is a secondary optimization (avoids re-opening files read multiple times). Dropping old entries just means a re-open on the next access — not a correctness issue.

**Alternative considered**: True LRU with access timestamps — rejected as overengineered. The BTreeMap's natural ordering gives us a deterministic eviction policy with zero overhead.

### 5. build_proxy: instance field instead of global static

**Decision**: Move `NEXT_HANDLE_ID` from `static AtomicUsize` to a `next_id: usize` field on `BuildFsHandler`. Use the same wrapping+collision pattern as the other daemons.

**Rationale**: Consistency with stored/profiled/virtio-fsd. The handler already takes `&mut self`, so no atomics needed. The global static was a shortcut from initial implementation.

## Risks / Trade-offs

- **[setrens breaks eprintln after init]** → Tested: stderr fd is already open before setrens. Writes to an open fd work regardless of namespace state. Confirmed by virtio-fsd which calls setrens and continues logging.
- **[root_fd gives full filesystem access]** → True, but the security improvement is blocking new scheme connections (network, IPC, etc.), not filesystem access. Same trade-off as build_proxy and virtio-fsd.
- **[FileIoWorker root_fd requires cfg(target_os = "redox")]** → The raw syscall path is Redox-only. Tests on Linux use the existing `std::fs` fallback (root_fd = None). No test coverage gap.
- **[Cache eviction drops valid fds]** → Only affects performance (re-open on next access), not correctness. The scheme handler's `Vec<u8>` content cache is unaffected.
