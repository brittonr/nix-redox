## ADDED Requirements

### Requirement: Debug logging on scheme entry points
The scheme handler SHALL emit a `log::debug!` message at the entry of every `SchemeSync` trait method: `openat`, `read`, `write`, `ftruncate`, `fsize`, `fpath`, `fstat`, `fstatvfs`, `getdents`, `unlinkat`, `fevent`, and `on_close`. Each message MUST include the Redox handle ID and the operation name.

#### Scenario: Open operation logged
- **WHEN** a caller opens a file at path "cache/abc.narinfo"
- **THEN** the driver emits a debug log containing the operation name "openat", the path, and the assigned handle ID

#### Scenario: Read operation logged
- **WHEN** a caller reads from handle 5 at offset 0 for 4096 bytes
- **THEN** the driver emits a debug log containing "read", handle ID 5, offset 0, and requested size 4096

### Requirement: Warning logging on error paths
The scheme handler SHALL emit a `log::warn!` message on every error return path. The message MUST include the operation name, the handle ID (if available), and the error detail (translated errno or transport error description).

#### Scenario: FUSE error logged as warning
- **WHEN** a FUSE_LOOKUP returns error -2 (ENOENT) during an openat call for path "missing/file"
- **THEN** the driver emits a warning log containing "openat", the path "missing/file", and "ENOENT" or error code 2

#### Scenario: Transport error logged as warning
- **WHEN** a DMA allocation failure occurs during a read operation on handle 7
- **THEN** the driver emits a warning log containing "read", handle ID 7, and the transport error description

### Requirement: Logging does not affect error propagation
Log statements SHALL NOT alter the error value returned to the caller. The logging MUST be inserted before the error return, not in place of it.

#### Scenario: Error value preserved after logging
- **WHEN** a write operation fails with ENOSPC and the warning is logged
- **THEN** the caller receives exactly `Error::new(ENOSPC)`, unchanged by the logging code
