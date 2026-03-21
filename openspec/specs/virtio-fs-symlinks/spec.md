## ADDED Requirements

### Requirement: FUSE_READLINK resolves symlink targets
The `FuseSession` SHALL implement a `readlink` method that sends FUSE_READLINK for a given node ID and returns the symlink target path as a string.

#### Scenario: Read a symlink pointing to a store path
- **WHEN** a FUSE node is a symlink with target "/nix/store/abc-package/bin/tool"
- **THEN** `readlink(nodeid)` returns the string "/nix/store/abc-package/bin/tool"

#### Scenario: Readlink on a non-symlink returns error
- **WHEN** `readlink` is called on a regular file node
- **THEN** the host returns FUSE error EINVAL and the method returns the corresponding error

### Requirement: FUSE_SYMLINK creates symlinks
The `FuseSession` SHALL implement a `symlink` method that sends FUSE_SYMLINK to create a symlink with a given name in a parent directory, pointing to a given target path.

#### Scenario: Create a symlink in the shared directory
- **WHEN** `symlink(parent_nodeid, "link-name", "/target/path")` is called
- **THEN** a symlink named "link-name" is created in the parent directory pointing to "/target/path"
- **AND** the returned `FuseEntryOut` contains the new node's attributes with mode `S_IFLNK`

### Requirement: Scheme openat follows symlinks transparently
When `resolve_path` encounters a symlink during path traversal, it SHALL call `readlink` to get the target, then continue resolution from the target path. This makes symlinks transparent to callers opening files through the scheme.

#### Scenario: Open a file through a symlink
- **WHEN** a caller opens "/scheme/shared/link-to-dir/file.txt" where "link-to-dir" is a symlink to "real-dir"
- **THEN** the open succeeds and returns the contents of "real-dir/file.txt"

#### Scenario: Symlink loop detection
- **WHEN** path resolution encounters more than 40 symlink hops
- **THEN** the scheme returns `Error::new(ELOOP)`

### Requirement: Stat reports S_IFLNK for symlinks
When a symlink node is opened with `O_STAT` (without following), `fstat` SHALL report `st_mode` with `S_IFLNK` set in the file type bits.

#### Scenario: Stat a symlink node
- **WHEN** a caller opens a symlink with `O_STAT` and calls fstat
- **THEN** the returned `Stat.st_mode` has the `S_IFLNK` type bits set

### Requirement: Getdents reports symlink type
When listing a directory containing symlinks, `getdents` SHALL report `DirentKind::Symlink` for entries with FUSE dirent type 10 (DT_LNK).

#### Scenario: Directory listing includes symlinks
- **WHEN** a directory contains a symlink entry
- **THEN** getdents reports it with `DirentKind::Symlink` (type 10 already handled in current code)
## ADDED Requirements

### Requirement: VM functional test validates symlink behavior through virtio-fs
A VM functional test SHALL verify end-to-end symlink support through the virtio-fs build bridge. The test SHALL create symlinks on the host side in the shared directory and verify from the Redox guest that symlinks are correctly traversed, stat'd, and listed.

#### Scenario: Read file through a symlink
- **WHEN** the host shared directory contains `target.txt` and a symlink `link.txt → target.txt`
- **THEN** reading `/scheme/shared/link.txt` from the guest returns the contents of `target.txt`

#### Scenario: Stat a symlink reports S_IFLNK
- **WHEN** the guest opens `/scheme/shared/link.txt` with O_STAT
- **THEN** `fstat` reports `st_mode` with S_IFLNK type bits

#### Scenario: Directory listing shows symlink type
- **WHEN** the guest lists a directory containing symlinks
- **THEN** `getdents` reports DirentKind::Symlink (DT_LNK = 10) for symlink entries

#### Scenario: Symlink chain traversal
- **WHEN** `a → b → target.txt` (two-hop symlink chain) exists in the shared directory
- **THEN** reading through `a` resolves both hops and returns the target's contents
