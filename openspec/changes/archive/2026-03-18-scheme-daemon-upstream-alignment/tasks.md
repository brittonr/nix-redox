## 1. Handle ID Safety

- [x] 1.1 Add `next_handle_id` helper to `stored/handles.rs` — wraps at `usize::MAX - 4096`, checks `handles` BTreeMap for collisions, replaces all `fetch_add` call sites in the file
- [x] 1.2 Add `next_handle_id` helper to `profiled/handles.rs` — same pattern, replaces all `fetch_add` call sites
- [x] 1.3 Move `NEXT_HANDLE_ID` global static in `build_proxy/handler.rs` to a `next_id: usize` field on `BuildFsHandler`, add wrapping+collision helper using `self.handles` HashMap, update `scheme_root` and `openat`
- [x] 1.4 Add wrapping+collision helper to `virtio-fsd/src/scheme.rs` — same pattern using the `handles` BTreeMap, replace all `fetch_add` call sites
- [x] 1.5 Add unit tests for handle ID wrapping and collision detection in `stored/handles.rs`

## 2. FileIoWorker root_fd Bypass

- [x] 2.1 Add `root_fd: Option<usize>` field to `FileIoWorker` and threading through `spawn()` → worker thread closure
- [x] 2.2 Add Redox-only raw open helper (`cfg(target_os = "redox")`) inside `file_io_worker.rs` — uses `SYS_OPENAT(root_fd, path, O_RDONLY)` + `File::from_raw_fd()`
- [x] 2.3 Modify `worker_read` and `worker_preload` to use raw open when `root_fd` is Some, fallback to `std::fs` when None
- [x] 2.4 Update `HandleTable::with_io_worker()` in stored and profiled to accept and pass through `root_fd`
- [x] 2.5 Verify existing FileIoWorker tests still pass (they use root_fd=None, std::fs fallback)

## 3. Null Namespace for stored/profiled

- [x] 3.1 In `stored/scheme.rs` `run_daemon`: pre-open `/` after creating daemon, pass root_fd to HandleTable's io_worker, call `setrens(0, 0)` after `register_sync_scheme` and before event loop
- [x] 3.2 In `profiled/scheme.rs` `run_daemon`: same sequence — pre-open `/`, pass root_fd to handles' io_worker, call `setrens(0, 0)` after scheme registration

## 4. fevent Support

- [x] 4.1 Add `fevent` override to `StoreSchemeHandler` in `stored/scheme.rs` — EVENT_READ for File/Dir, EVENT_WRITE for Control, EBADF for missing
- [x] 4.2 Add `fevent` override to `ProfileSchemeHandler` in `profiled/scheme.rs` — same semantics
- [x] 4.3 Add `fevent` override to `BuildFsHandler` in `build_proxy/handler.rs` — EVENT_READ for Dir and read-only File, EVENT_READ|EVENT_WRITE for writable File, EBADF for missing

## 5. FileIoWorker Cache Eviction

- [x] 5.1 Add `const MAX_FILE_CACHE: usize = 64` and eviction logic in `worker_read` — when cache exceeds limit, remove first BTreeMap entry before inserting
- [x] 5.2 Add test for cache eviction behavior in `file_io_worker.rs`
