## Why

The virtio-fsd driver is the sole transport for the snix build bridge — every NAR, narinfo, and JSON request/response flows through it. When something goes wrong, diagnosing the failure is nearly impossible: all FUSE errors get mapped to generic `EIO`/`ENOENT` (the real errno is discarded), and the 747-line scheme handler has zero logging. Symlinks — which the Nix store uses heavily — aren't supported at all, forcing workarounds in the cache layout. These gaps compound: a host-side `EACCES` looks identical to `ENOSPC` to the guest, and there's no log trail to distinguish them.

## What Changes

- **FUSE-to-Redox errno translation**: Map the FUSE error code from `FuseTransportError::FuseError(i32)` to the corresponding Redox `syscall::error` constant instead of discarding it. Covers the ~15 errno values that FUSE/Linux and Redox share (ENOENT, EACCES, ENOSPC, EEXIST, EISDIR, ENOTDIR, EINVAL, EPERM, ENOTEMPTY, ENOSYS, ENOMEM, ERANGE, EBUSY, ELOOP, ENAMETOOLONG).
- **Operation logging in scheme.rs**: Add `log::debug!` on every scheme entry point (open, read, write, readdir, unlink, close) and `log::warn!` on every error path. Gives a full trace of what the driver is doing at debug level, errors always visible.
- **Symlink support**: Implement FUSE_READLINK (resolve symlink target) and FUSE_SYMLINK (create symlink). Wire into the scheme layer so symlinks in the shared directory are accessible from Redox. Report `S_IFLNK` correctly in stat.
- **Read/write chunking**: When a read or write exceeds the negotiated `max_write`/`max_read`, split into multiple FUSE operations transparently. Prevents `RequestTooLarge` errors on large NAR transfers.
- **FUSE_FLUSH on close**: Send FUSE_FLUSH before FUSE_RELEASE so the host flushes dirty pages before the file handle is freed.

## Capabilities

### New Capabilities
- `fuse-errno-mapping`: Translating FUSE/Linux errno values to Redox syscall error constants, preserving error semantics across the virtio-fs boundary.
- `virtio-fs-logging`: Structured operation logging in the virtio-fs scheme handler for tracing and debugging.
- `virtio-fs-symlinks`: FUSE symlink operations (READLINK, SYMLINK) and correct S_IFLNK handling in the Redox scheme layer.
- `virtio-fs-chunked-io`: Transparent chunking of reads and writes that exceed the FUSE-negotiated maximum transfer size.
- `virtio-fs-flush`: Sending FUSE_FLUSH before FUSE_RELEASE to ensure host-side write durability.

### Modified Capabilities

## Impact

- **Files**: `nix/pkgs/system/virtio-fsd/src/{scheme.rs,session.rs,fuse.rs,transport.rs}`
- **APIs**: No external API changes. `FuseSession` gains new methods (`readlink`, `symlink`, `flush`). `FuseTransportError::FuseError` gets a helper to convert to Redox errno.
- **Dependencies**: None added.
- **Testing**: Bridge test (`bridge-test.nix`) exercises the shared directory path. Existing tests validate the basic flow; symlink and error cases would need new test coverage in the functional test scripts.
