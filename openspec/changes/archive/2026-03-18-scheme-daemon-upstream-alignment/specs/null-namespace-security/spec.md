## ADDED Requirements

### Requirement: stored enters null namespace after initialization
The stored daemon SHALL call `setrens(0, 0)` after scheme registration and before entering the event loop.

#### Scenario: Null namespace after registration
- **WHEN** stored completes scheme registration
- **THEN** it calls `setrens(0, 0)` before processing any client requests

### Requirement: profiled enters null namespace after initialization
The profiled daemon SHALL call `setrens(0, 0)` after scheme registration and before entering the event loop.

#### Scenario: Null namespace after registration
- **WHEN** profiled completes scheme registration
- **THEN** it calls `setrens(0, 0)` before processing any client requests

### Requirement: FileIoWorker supports root_fd bypass
The FileIoWorker SHALL accept an optional `root_fd` parameter. When set, all file open operations SHALL use `SYS_OPENAT(root_fd, path, ...)` instead of `std::fs::File::open()`.

#### Scenario: root_fd set on Redox
- **WHEN** FileIoWorker is created with `root_fd = Some(fd)`
- **THEN** file opens use `SYS_OPENAT(fd, path, O_RDONLY)` bypassing the namespace

#### Scenario: root_fd not set (tests/Linux)
- **WHEN** FileIoWorker is created with `root_fd = None`
- **THEN** file opens use `std::fs::File::open()` as today

### Requirement: Root fd opened before setrens
The stored and profiled daemons SHALL open `/` to obtain a root fd before calling `setrens(0, 0)`, and pass this fd to the FileIoWorker.

#### Scenario: Pre-open sequence
- **WHEN** the daemon initializes
- **THEN** it opens `/` to get a root fd
- **THEN** it passes the root fd to the FileIoWorker
- **THEN** it registers the scheme
- **THEN** it calls `setrens(0, 0)`
