## 1. FUSE Errno Translation

- [x] 1.1 Add `fuse_error_to_redox(fuse_errno: i32) -> Error` function to `scheme.rs` with match arms for ENOENT(2), EACCES(13), ENOSPC(28), EEXIST(17), EISDIR(21), ENOTDIR(20), EINVAL(22), EPERM(1), ENOTEMPTY(39), ENOSYS(38), ENOMEM(12), ERANGE(34), EBUSY(16), ELOOP(40), ENAMETOOLONG(36), falling back to EIO
- [x] 1.2 Add `fuse_err(e: FuseTransportError) -> Error` helper that extracts the errno from `FuseError` variant and calls `fuse_error_to_redox`, returning `EIO` for non-FUSE transport errors
- [x] 1.3 Replace all `.map_err(|_| Error::new(EIO))` and `.map_err(|_| Error::new(ENOENT))` calls in `scheme.rs` with `.map_err(fuse_err)`
- [x] 1.4 Import any missing errno constants into `scheme.rs` (ENOSPC, EINVAL, EPERM, ENOTEMPTY, ENOMEM, ERANGE, EBUSY, ELOOP, ENAMETOOLONG)

## 2. Operation Logging

- [x] 2.1 Add `log::debug!` at entry of `openat` with dirfd, path, and flags
- [x] 2.2 Add `log::debug!` at entry of `read` and `write` with handle ID, offset, and size
- [x] 2.3 Add `log::debug!` at entry of `ftruncate`, `fsize`, `fpath`, `fstat`, `fstatvfs` with handle ID
- [x] 2.4 Add `log::debug!` at entry of `getdents` with handle ID and opaque_offset
- [x] 2.5 Add `log::debug!` at entry of `unlinkat` with fd and path
- [x] 2.6 Add `log::debug!` at entry of `on_close` with handle ID and is_dir/writable state
- [x] 2.7 Add `log::warn!` on every error return in scheme methods, including the operation name and translated error

## 3. FUSE Protocol Extensions (fuse.rs + session.rs)

- [x] 3.1 Add `FuseSymlinkIn` comment noting FUSE_SYMLINK has no fixed struct (just `target\0name\0` in the request body) and uncomment Readlink/Symlink in the opcode enum
- [x] 3.2 Add `FuseFlushIn` struct to `fuse.rs` with fields `fh: u64`, `unused: u32`, `padding: u32`, `lock_owner: u64`
- [x] 3.3 Implement `FuseSession::readlink(nodeid) -> Result<String>` — sends FUSE_READLINK, response body is raw target bytes
- [x] 3.4 Implement `FuseSession::symlink(parent, name, target) -> Result<FuseEntryOut>` — sends FUSE_SYMLINK with `target\0name\0` body
- [x] 3.5 Implement `FuseSession::flush(nodeid, fh) -> Result<()>` — sends FUSE_FLUSH with `FuseFlushIn`

## 4. Symlink Support in Scheme Layer

- [x] 4.1 Modify `resolve_path` to accept a `max_hops: u32` parameter (default 40) and track hop count
- [x] 4.2 After each FUSE_LOOKUP in `resolve_path`, check if the returned attr has `S_IFLNK` mode — if so, call `readlink`, parse the target, and continue resolution (incrementing hops, returning ELOOP if exceeded)
- [x] 4.3 Handle absolute symlink targets (restart from FUSE root nodeid 1) and relative targets (continue from current parent) in `resolve_path`
- [x] 4.4 Wire `symlink` into `openat` or add as a separate scheme operation if Redox supports it (check SchemeSync trait for symlink method)

## 5. Read/Write Chunking

- [x] 5.1 Store `effective_max_io` as `min(max_write as usize, MAX_IO_SIZE)` in `FuseSession` during init
- [x] 5.2 Modify `FuseSession::read` to loop when `size > effective_max_io`: issue chunks of `effective_max_io`, concatenate results, stop on short read (fewer bytes than chunk size)
- [x] 5.3 Modify `FuseSession::write` to loop when `data.len() > effective_max_io`: write chunks of `effective_max_io`, advance offset by bytes-written, stop on short write
- [x] 5.4 Verify existing callers in `scheme.rs` are unchanged (they pass through size/data without caring about chunking)

## 6. Flush on Close

- [x] 6.1 Modify `on_close` in `scheme.rs`: before calling `release`, check if `handle.writable && !handle.is_dir`
- [x] 6.2 If writable, call `session.flush(nodeid, fh)` — log any error at `log::warn!` but do not skip release
- [x] 6.3 Proceed to `release`/`releasedir` as before regardless of flush result

## 7. Verification

- [x] 7.1 Build virtio-fsd cross-compiled for Redox (confirm it compiles with all changes)
- [x] 7.2 Run `bridge-test` to verify basic bridge flow still works (open, read, write, readdir, close)
- [x] 7.3 Test symlink handling: add a symlink to the shared directory on host, verify guest can read through it
- [x] 7.4 Test error propagation: create a read-only file on host, attempt write from guest, verify EACCES (not EIO)
