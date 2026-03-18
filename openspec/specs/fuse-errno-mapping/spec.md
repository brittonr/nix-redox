## ADDED Requirements

### Requirement: FUSE error codes map to Redox errno
The driver SHALL translate negative FUSE error codes from `FuseTransportError::FuseError(i32)` to the corresponding Redox `syscall::error` constant. The translation MUST cover: ENOENT, EACCES, ENOSPC, EEXIST, EISDIR, ENOTDIR, EINVAL, EPERM, ENOTEMPTY, ENOSYS, ENOMEM, ERANGE, EBUSY, ELOOP, ENAMETOOLONG. Unrecognized FUSE error codes SHALL fall back to EIO.

#### Scenario: Host returns EACCES on open
- **WHEN** the host virtiofsd returns FUSE error -13 (EACCES) for an open operation
- **THEN** the Redox scheme handler returns `Error::new(EACCES)` to the caller

#### Scenario: Host returns ENOSPC on write
- **WHEN** the host virtiofsd returns FUSE error -28 (ENOSPC) for a write operation
- **THEN** the Redox scheme handler returns `Error::new(ENOSPC)` to the caller

#### Scenario: Host returns ENOTEMPTY on rmdir
- **WHEN** the host virtiofsd returns FUSE error -39 (ENOTEMPTY) for an rmdir operation
- **THEN** the Redox scheme handler returns `Error::new(ENOTEMPTY)` to the caller

#### Scenario: Unknown FUSE error falls back to EIO
- **WHEN** the host virtiofsd returns an unrecognized FUSE error code (e.g., -999)
- **THEN** the Redox scheme handler returns `Error::new(EIO)` to the caller

### Requirement: Scheme methods use translated errors throughout
Every scheme method that calls a `FuseSession` operation SHALL use the errno translation function on the error path instead of hardcoded `EIO` or `ENOENT`. This applies to `openat`, `read`, `write`, `ftruncate`, `fsize`, `fstat`, `fstatvfs`, `getdents`, and `unlinkat`.

#### Scenario: Consistent error mapping across all operations
- **WHEN** any FuseSession method returns a `FuseTransportError::FuseError` in any scheme method
- **THEN** the error SHALL be translated through the errno mapping function, not hardcoded
