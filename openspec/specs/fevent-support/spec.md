## ADDED Requirements

### Requirement: stored implements fevent
The stored scheme handler SHALL implement `fevent` returning `EVENT_READ` for file and directory handles, and `EVENT_WRITE` for control handles.

#### Scenario: fevent on file handle
- **WHEN** a client calls fevent on an open file handle
- **THEN** the daemon returns `EVENT_READ`

#### Scenario: fevent on directory handle
- **WHEN** a client calls fevent on an open directory handle
- **THEN** the daemon returns `EVENT_READ`

#### Scenario: fevent on control handle
- **WHEN** a client calls fevent on a `.control` handle
- **THEN** the daemon returns `EVENT_WRITE`

#### Scenario: fevent on invalid handle
- **WHEN** a client calls fevent on a nonexistent handle ID
- **THEN** the daemon returns `EBADF`

### Requirement: profiled implements fevent
The profiled scheme handler SHALL implement `fevent` with the same semantics as stored.

#### Scenario: fevent on file handle
- **WHEN** a client calls fevent on an open file handle
- **THEN** the daemon returns `EVENT_READ`

#### Scenario: fevent on control handle
- **WHEN** a client calls fevent on a `.control` handle
- **THEN** the daemon returns `EVENT_WRITE`

#### Scenario: fevent on invalid handle
- **WHEN** a client calls fevent on a nonexistent handle ID
- **THEN** the daemon returns `EBADF`

### Requirement: build_proxy implements fevent
The build_proxy scheme handler SHALL implement `fevent` returning `EVENT_READ` for read-only file handles, `EVENT_READ | EVENT_WRITE` for writable file handles, and `EVENT_READ` for directory handles.

#### Scenario: fevent on read-only file
- **WHEN** a client calls fevent on a file handle opened read-only
- **THEN** the daemon returns `EVENT_READ`

#### Scenario: fevent on writable file
- **WHEN** a client calls fevent on a file handle opened for writing
- **THEN** the daemon returns `EVENT_READ | EVENT_WRITE`

#### Scenario: fevent on directory
- **WHEN** a client calls fevent on a directory handle
- **THEN** the daemon returns `EVENT_READ`

#### Scenario: fevent on invalid handle
- **WHEN** a client calls fevent on a nonexistent handle ID
- **THEN** the daemon returns `EBADF`
