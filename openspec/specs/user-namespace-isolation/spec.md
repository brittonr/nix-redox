## ADDED Requirements

### Requirement: Per-user scheme list declaration
The module system SHALL accept an optional `schemes` attribute on each user in `/users.users`. When present, the build system SHALL generate a `[user_schemes.<username>]` entry in `/etc/login_schemes.toml` with the user's scheme list. When absent, no entry is generated and userutils `login` falls through to `DEFAULT_SCHEMES`.

#### Scenario: User with explicit scheme list
- **WHEN** a user is declared with `schemes = ["file" "pipe" "pty" "null" "zero" "rand" "tcp" "udp"]`
- **THEN** `/etc/login_schemes.toml` SHALL contain a `[user_schemes.<username>]` section with `schemes = ["file", "pipe", "pty", "null", "zero", "rand", "tcp", "udp"]`

#### Scenario: User without scheme list
- **WHEN** a user is declared without a `schemes` attribute
- **THEN** `/etc/login_schemes.toml` SHALL NOT contain a `[user_schemes.<username>]` section for that user

#### Scenario: Root user default
- **WHEN** the root user has no explicit `schemes` override
- **THEN** `/etc/login_schemes.toml` SHALL contain a `[user_schemes.root]` section with all 26 DEFAULT_SCHEMES plus `proc`

### Requirement: Restricted default scheme set for non-root users
When a non-root user is declared with `schemes = "restricted"` (the string literal), the build system SHALL generate a scheme list that excludes kernel-internal schemes: `irq`, `sys`, `memory`, `serio`. The restricted set SHALL include: `debug`, `event`, `pipe`, `time`, `rand`, `null`, `zero`, `log`, `ip`, `icmp`, `tcp`, `udp`, `shm`, `chan`, `uds_stream`, `uds_dgram`, `file`, `display.vesa`, `display*`, `pty`, `sudo`, `audio`.

#### Scenario: Restricted scheme set generation
- **WHEN** a user is declared with `schemes = "restricted"`
- **THEN** the generated `login_schemes.toml` entry SHALL contain exactly the restricted set (22 schemes, no `irq`, `sys`, `memory`, `serio`)

### Requirement: Namespace isolation at runtime
When a user logs in via the `login` binary, the process SHALL be placed in a namespace containing only the schemes from `login_schemes.toml` (or DEFAULT_SCHEMES). Schemes not in the namespace SHALL be invisible to the user's processes.

#### Scenario: Restricted user cannot see kernel schemes
- **WHEN** a user with restricted schemes runs `ls :` (list schemes in namespace)
- **THEN** the output SHALL NOT contain `irq`, `sys`, `memory`, or `serio`

#### Scenario: Root user can see all schemes
- **WHEN** root runs `ls :` after login
- **THEN** the output SHALL contain `proc`, `sys`, `irq`, and all other declared schemes that are running

### Requirement: File ownership enforcement
Home directories SHALL be owned by their respective user (uid/gid set via redoxfs-ar). A user SHALL be able to write files in their own home directory. A non-root user SHALL NOT be able to write to another user's home directory or to `/root`.

#### Scenario: User writes to own home
- **WHEN** a process running as uid 1000 writes a file to `/home/user/test`
- **THEN** the write SHALL succeed

#### Scenario: User cannot write to root home
- **WHEN** a process running as uid 1000 attempts to write to `/root/test`
- **THEN** the write SHALL fail with a permission error
