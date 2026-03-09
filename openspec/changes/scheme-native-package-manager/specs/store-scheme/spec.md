## ADDED Requirements

### Requirement: Store scheme daemon registration

`stored` SHALL register the `store` scheme with the Redox kernel by opening `/scheme/store` with `O_CREAT`. The daemon SHALL enter a request loop processing `Packet` structs from the kernel and dispatching to the appropriate handler (open, read, close, stat, readdir). The daemon SHALL implement the `SchemeBlockMut` trait from the `redox_scheme` crate.

#### Scenario: Daemon starts and registers scheme
- **WHEN** `stored` is started (e.g., by init)
- **THEN** it SHALL register the `store` scheme and begin accepting requests

#### Scenario: Scheme already registered
- **WHEN** `stored` starts and the `store` scheme is already registered by another process
- **THEN** it SHALL exit with an error message indicating the scheme is already in use

### Requirement: Store path resolution

When a process opens a path via the `store:` scheme (e.g., `open("store:abc...-ripgrep/bin/rg")`), `stored` SHALL resolve the scheme-relative path to the corresponding filesystem path under `/nix/store/`. The mapping SHALL be `store:{path}` → `/nix/store/{path}`.

#### Scenario: Open file in extracted store path
- **WHEN** a process opens `store:abc...-ripgrep/bin/rg` and the store path is extracted
- **THEN** `stored` SHALL return a file descriptor for `/nix/store/abc...-ripgrep/bin/rg`

#### Scenario: Open file in missing store path
- **WHEN** a process opens `store:abc...-ripgrep/bin/rg` and `/nix/store/abc...-ripgrep/` does not exist
- **THEN** `stored` SHALL attempt lazy extraction before returning the file descriptor (see lazy extraction requirement)

#### Scenario: Path does not exist after extraction
- **WHEN** a process opens a path that does not exist within an extracted store path
- **THEN** `stored` SHALL return `ENOENT`

#### Scenario: Store path not registered in PathInfoDb
- **WHEN** a process opens a path whose store path hash is not in PathInfoDb
- **THEN** `stored` SHALL return `ENOENT`

### Requirement: Lazy NAR extraction on first access

When a store path is registered in PathInfoDb but not yet extracted to the filesystem, `stored` SHALL extract the NAR on the first access to any file within that store path. Extraction SHALL decompress the NAR (zstd, xz, bzip2, or uncompressed), verify the SHA-256 hash, and write the contents to `/nix/store/{hash}-{name}/`. After extraction, the original open request SHALL be completed by serving the file from the filesystem.

#### Scenario: First access triggers extraction
- **WHEN** a process opens a file in a store path that is registered but not extracted
- **THEN** `stored` SHALL extract the full NAR to `/nix/store/`, verify the hash, and then serve the requested file

#### Scenario: Extraction source is local cache
- **WHEN** the NAR file exists in the local cache (e.g., `/nix/cache/{hash}.nar.zst`)
- **THEN** `stored` SHALL read from the local cache for extraction

#### Scenario: NAR hash verification failure
- **WHEN** the extracted NAR hash does not match the PathInfoDb record
- **THEN** `stored` SHALL delete the partial extraction, log the error, and return `EIO` to the caller

#### Scenario: Concurrent access during extraction
- **WHEN** multiple processes open files in the same store path simultaneously and extraction is in progress
- **THEN** `stored` SHALL block subsequent requests until extraction completes, then serve all pending requests from the extracted filesystem

#### Scenario: Cache file missing
- **WHEN** a store path is registered but the NAR file is not found in any configured cache
- **THEN** `stored` SHALL return `ENOENT` and log a warning

### Requirement: File descriptor management

`stored` SHALL maintain a handle table mapping open file descriptors to underlying filesystem file descriptors or in-progress operations. The handle table SHALL support concurrent reads from multiple processes.

#### Scenario: Open returns a handle ID
- **WHEN** a process successfully opens a file through `store:`
- **THEN** `stored` SHALL allocate a handle ID and return it as the file descriptor

#### Scenario: Read uses handle to serve data
- **WHEN** a process reads from an open `store:` handle
- **THEN** `stored` SHALL read from the underlying filesystem file at the correct offset

#### Scenario: Close releases the handle
- **WHEN** a process closes a `store:` file descriptor
- **THEN** `stored` SHALL release the handle and close the underlying filesystem fd

#### Scenario: Stat returns file metadata
- **WHEN** a process stats a `store:` path
- **THEN** `stored` SHALL return the filesystem metadata (size, permissions, type) of the resolved path

### Requirement: Directory listing

`stored` SHALL support `readdir` on store path directories. Listing `store:abc...-ripgrep/` SHALL return the directory contents of `/nix/store/abc...-ripgrep/`. Listing the store root (`store:`) SHALL return all registered store path names.

#### Scenario: List store path contents
- **WHEN** a process reads the directory `store:abc...-ripgrep/bin/`
- **THEN** `stored` SHALL return the directory entries from `/nix/store/abc...-ripgrep/bin/`

#### Scenario: List store root
- **WHEN** a process reads the directory `store:`
- **THEN** `stored` SHALL return all store path names from PathInfoDb (both extracted and registered-but-not-extracted)

### Requirement: PathInfoDb integration

`stored` SHALL read from the existing PathInfoDb at `/nix/var/snix/pathinfo/` to determine which store paths are registered, their NAR hashes, and their cache locations. `stored` SHALL NOT maintain a separate database — PathInfoDb is the single source of truth.

#### Scenario: Daemon loads PathInfoDb on startup
- **WHEN** `stored` starts
- **THEN** it SHALL scan PathInfoDb to build an in-memory index of registered store paths

#### Scenario: New paths registered while running
- **WHEN** `snix install` registers a new path in PathInfoDb while `stored` is running
- **THEN** `stored` SHALL detect the new path on next access (by re-checking PathInfoDb on cache miss)

### Requirement: Graceful fallback when daemon is not running

When `stored` is not running, opening `store:` paths SHALL fail with `ENOENT` (scheme not registered). All snix CLI operations SHALL detect this and fall back to direct filesystem access at `/nix/store/`.

#### Scenario: stored not running, snix install
- **WHEN** `snix install ripgrep` runs and `stored` is not running
- **THEN** snix SHALL extract the NAR directly to `/nix/store/` as it does today

#### Scenario: stored not running, direct access
- **WHEN** a process accesses `/nix/store/abc...-ripgrep/bin/rg` directly (not via scheme)
- **THEN** the access SHALL work normally via the `file:` scheme regardless of whether `stored` is running
