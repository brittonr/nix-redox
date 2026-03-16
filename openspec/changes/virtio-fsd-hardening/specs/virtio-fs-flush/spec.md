## ADDED Requirements

### Requirement: FUSE_FLUSH sent before FUSE_RELEASE
The `FuseSession` SHALL implement a `flush` method that sends FUSE_FLUSH for a given node ID and file handle. The scheme's `on_close` handler SHALL call `flush` before `release` for writable file handles.

#### Scenario: Writable file flushed on close
- **WHEN** a writable file handle is closed via `on_close`
- **THEN** FUSE_FLUSH is sent to the host before FUSE_RELEASE
- **AND** the host flushes pending writes to stable storage before releasing the handle

#### Scenario: Read-only file skips flush
- **WHEN** a read-only file handle is closed via `on_close`
- **THEN** FUSE_RELEASE is sent without a preceding FUSE_FLUSH (no dirty data to flush)

#### Scenario: Directory handles skip flush
- **WHEN** a directory handle is closed via `on_close`
- **THEN** FUSE_RELEASEDIR is sent without a preceding FUSE_FLUSH

### Requirement: Flush errors do not prevent release
If FUSE_FLUSH returns an error, the scheme SHALL log the error but still proceed to send FUSE_RELEASE. The file handle MUST always be released to avoid resource leaks on the host.

#### Scenario: Flush fails but release succeeds
- **WHEN** FUSE_FLUSH returns an error (e.g., host I/O error)
- **THEN** the error is logged as a warning
- **AND** FUSE_RELEASE is still sent and the handle is removed from the handle map
