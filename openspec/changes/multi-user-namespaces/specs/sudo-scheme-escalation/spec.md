## ADDED Requirements

### Requirement: Sudo daemon validates group membership
The sudod scheme daemon SHALL verify that the calling user is a member of the `sudo` group before accepting a password. Users not in the `sudo` group SHALL be denied regardless of password correctness.

#### Scenario: User in sudo group authenticates
- **WHEN** a user in the `sudo` group opens `/scheme/sudo` and writes the correct password
- **THEN** the daemon SHALL accept the authentication and allow privilege escalation

#### Scenario: User not in sudo group denied
- **WHEN** a user NOT in the `sudo` group opens `/scheme/sudo` and writes any password
- **THEN** the daemon SHALL return EPERM

### Requirement: Su authenticates via sudo scheme
The `su` binary SHALL authenticate by opening `/scheme/sudo/su` and writing the target user's password. On success, `su` SHALL spawn the target user's shell.

#### Scenario: Su to root with correct password
- **WHEN** a non-root user runs `su` and provides root's password
- **THEN** the spawned shell SHALL run as uid 0

#### Scenario: Su to root with blank password
- **WHEN** root has an empty password and a non-root user runs `su`
- **THEN** `su` SHALL authenticate the empty password and spawn root's shell

### Requirement: Sudo elevates caller's process
The `sudo` binary SHALL send its process fd to the sudod daemon after password verification. The daemon SHALL call `SetResugid(0,0,0,0,0,0)` on the caller's process, setting all uid/gid values to root. The elevated process SHALL then exec the requested command.

#### Scenario: Sudo runs command as root
- **WHEN** user 1000 (in sudo group) runs `sudo id -u`
- **THEN** the output SHALL be `0`

### Requirement: Id reports correct user identity
The `id` binary SHALL report the effective uid, gid, username, and groupname of the calling process as returned by the kernel.

#### Scenario: Id as root
- **WHEN** root runs `id`
- **THEN** the output SHALL contain `uid=0(root)` and `gid=0(root)`

#### Scenario: Id as non-root user
- **WHEN** user 1000 runs `id`
- **THEN** the output SHALL contain `uid=1000(user)` and `gid=1000(user)`

#### Scenario: Whoami as non-root user
- **WHEN** user 1000 runs `whoami` (symlink to `id -un`)
- **THEN** the output SHALL be `user`
