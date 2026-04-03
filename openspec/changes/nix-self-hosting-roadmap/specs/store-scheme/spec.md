## MODIFIED Requirements

### Requirement: Store scheme daemon registration

`stored` SHALL register the `store` scheme with the Redox kernel by opening `/scheme/store` with `O_CREAT`. The daemon SHALL enter a request loop processing `Packet` structs from the kernel and dispatching to the appropriate handler (open, read, close, stat, readdir). The daemon SHALL implement the `SchemeBlockMut` trait from the `redox_scheme` crate.

All file I/O within the daemon (NAR extraction, reading from `/nix/store/`, reading from `/nix/cache/`) SHALL use the pre-opened root fd pattern (`SYS_OPENAT(root_fd, path, ...)`) to bypass initnsmgr and prevent circular deadlocks.

#### Scenario: Daemon starts and registers scheme
- **WHEN** `stored` is started by init
- **THEN** it SHALL register the `store` scheme and begin accepting requests

#### Scenario: Scheme already registered
- **WHEN** `stored` starts and the `store` scheme is already registered by another process
- **THEN** it SHALL exit with an error message indicating the scheme is already in use

#### Scenario: File I/O bypasses initnsmgr
- **WHEN** `stored` reads a NAR from `/nix/cache/` during lazy extraction
- **THEN** the read SHALL use the pre-opened root fd, not `File::open()`
- **AND** no request SHALL route through initnsmgr

### Requirement: Store path resolution

When a process opens a path via the `store:` scheme (e.g., `open("store:abc...-ripgrep/bin/rg")`), `stored` SHALL resolve the scheme-relative path to the corresponding filesystem path under `/nix/store/`. The mapping SHALL be `store:{path}` -> `/nix/store/{path}`.

#### Scenario: Open file in extracted store path
- **WHEN** a process opens `store:abc...-ripgrep/bin/rg` and the store path is already extracted
- **THEN** `stored` SHALL return a file descriptor for `/nix/store/abc...-ripgrep/bin/rg`

#### Scenario: Path does not exist after extraction
- **WHEN** a process opens a path that does not exist within an extracted store path
- **THEN** `stored` SHALL return `ENOENT`

### Requirement: Lazy NAR extraction on first access

When a process opens a store path that is registered in the PathInfoDb but not yet extracted to `/nix/store/`, `stored` SHALL extract the NAR from the local cache, verify the hash, and then serve the requested file. Subsequent accesses to the same store path SHALL go directly to the filesystem without re-extraction.

#### Scenario: First access triggers extraction
- **WHEN** a process opens `store:abc...-ripgrep/bin/rg`
- **AND** `/nix/store/abc...-ripgrep/` does not exist
- **AND** the PathInfoDb has an entry for `abc...-ripgrep`
- **THEN** `stored` SHALL extract the NAR from `/nix/cache/`
- **AND** verify the NAR hash
- **AND** return a file descriptor for the requested file

#### Scenario: Second access skips extraction
- **WHEN** a process opens `store:abc...-ripgrep/bin/rg` a second time
- **AND** `/nix/store/abc...-ripgrep/` already exists from the first access
- **THEN** `stored` SHALL serve the file directly without re-extraction

#### Scenario: Unknown store path returns ENOENT
- **WHEN** a process opens `store:unknown-hash-name/bin/foo`
- **AND** the PathInfoDb has no entry for `unknown-hash-name`
- **THEN** `stored` SHALL return `ENOENT`

### Requirement: Init service integration

`stored` SHALL be started by init as a `daemon` type service before any services that depend on store paths. The service SHALL be listed in `login_schemes.toml` so user sessions can access `store:` paths.

#### Scenario: stored starts during boot
- **WHEN** the system boots with `stored` in the service list
- **THEN** `stored` registers the scheme and signals readiness before dependent services start

#### Scenario: User session can access store scheme
- **WHEN** a user logs in via getty
- **AND** `login_schemes.toml` includes `store` in the user's scheme list
- **THEN** the user can open `store:` paths from their shell
