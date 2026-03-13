## ADDED Requirements

### Requirement: Proxy scheme daemon filters file access by allow-list

The build filesystem proxy SHALL register itself as the `file` scheme in a child namespace and restrict filesystem access to paths listed in an allow-list derived from the derivation's declared inputs. Paths not on the allow-list SHALL be rejected.

#### Scenario: Builder opens a declared input store path
- **WHEN** the derivation declares `/nix/store/abc-dep-1.0` as an input
- **AND** the builder opens `/nix/store/abc-dep-1.0/lib/libfoo.so`
- **THEN** the proxy SHALL forward the open to the real filesystem and return success

#### Scenario: Builder opens an undeclared store path
- **WHEN** `/nix/store/xyz-other-2.0` is NOT in the derivation's inputs
- **AND** the builder opens `/nix/store/xyz-other-2.0/bin/bar`
- **THEN** the proxy SHALL return `EACCES`

#### Scenario: Builder opens a path outside /nix/store
- **WHEN** the builder opens `/home/user/.ssh/id_rsa`
- **THEN** the proxy SHALL return `EACCES`

#### Scenario: Builder opens /etc/passwd
- **WHEN** the builder opens `/etc/passwd`
- **THEN** the proxy SHALL return `EACCES`

### Requirement: Builder has read-write access to output directory

The builder's `$out` directory SHALL be on the allow-list with read and write permissions. The builder SHALL be able to create files, directories, and symlinks under `$out`.

#### Scenario: Builder writes a file to $out
- **WHEN** the builder creates `/nix/store/ghi-output-1.0/bin/hello`
- **AND** `/nix/store/ghi-output-1.0` is the derivation's `$out`
- **THEN** the proxy SHALL forward the write to the real filesystem and return success

#### Scenario: Builder reads back from $out
- **WHEN** the builder reads a file it previously wrote to `$out`
- **THEN** the proxy SHALL forward the read and return the file contents

#### Scenario: Builder creates directories under $out
- **WHEN** the builder calls `mkdir` under `$out`
- **THEN** the proxy SHALL forward the operation and return success

### Requirement: Builder has read-write access to temp directory

The builder's `$TMPDIR` SHALL be on the allow-list with read and write permissions. Build scripts use `$TMPDIR` for intermediate files, compiler temporaries, and scratch space.

#### Scenario: Builder writes temporary files
- **WHEN** the builder creates files under `/tmp/snix-build-42-0`
- **AND** that path is the derivation's `$TMPDIR`
- **THEN** the proxy SHALL forward the write and return success

#### Scenario: Builder reads temporary files
- **WHEN** the builder reads a file it created in `$TMPDIR`
- **THEN** the proxy SHALL return the file contents

### Requirement: Input store paths are read-only

Store paths from `input_derivations` (resolved outputs) and `input_sources` SHALL be on the allow-list as read-only. Builders SHALL NOT be able to modify input store paths.

#### Scenario: Builder reads an input source file
- **WHEN** the derivation lists `/nix/store/src-hash-source` in `input_sources`
- **AND** the builder reads `/nix/store/src-hash-source/default.nix`
- **THEN** the proxy SHALL return the file contents

#### Scenario: Builder attempts to write to an input store path
- **WHEN** the builder tries to write to `/nix/store/abc-dep-1.0/lib/libfoo.so`
- **AND** `/nix/store/abc-dep-1.0` is a read-only input
- **THEN** the proxy SHALL return `EACCES`

### Requirement: Allow-list uses prefix matching

Path access checks SHALL use prefix matching against the allow-list entries. A request for `/nix/store/abc-dep-1.0/lib/subdir/file.o` SHALL match the allow-list entry `/nix/store/abc-dep-1.0`.

#### Scenario: Nested path matches store path prefix
- **WHEN** `/nix/store/abc-dep-1.0` is on the allow-list
- **AND** the builder opens `/nix/store/abc-dep-1.0/share/doc/README.md`
- **THEN** the prefix match SHALL succeed and the open SHALL be forwarded

#### Scenario: Partial hash match does not grant access
- **WHEN** `/nix/store/abc-dep-1.0` is on the allow-list
- **AND** the builder opens `/nix/store/abc-dep-1.0-other-pkg/bin/foo`
- **THEN** the prefix match SHALL NOT succeed (the hash-name differs)
- **AND** the proxy SHALL return `EACCES`

### Requirement: Directory listings are filtered

When the builder lists a directory, the proxy SHALL only return entries that match the allow-list. Entries for paths the builder cannot access SHALL be omitted from the listing.

#### Scenario: Listing /nix/store shows only allowed paths
- **WHEN** the real `/nix/store/` contains 100 store paths
- **AND** the allow-list contains 5 store paths
- **AND** the builder calls `getdents` on `/nix/store/`
- **THEN** the proxy SHALL return only the 5 allowed entries

#### Scenario: Listing a subdirectory of an allowed path
- **WHEN** `/nix/store/abc-dep-1.0` is on the allow-list
- **AND** the builder lists `/nix/store/abc-dep-1.0/lib/`
- **THEN** the proxy SHALL return all entries in that real directory (all children of an allowed prefix are visible)

#### Scenario: Listing a directory with no allowed children
- **WHEN** the builder lists `/home/`
- **AND** no paths under `/home/` are on the allow-list
- **THEN** the proxy SHALL return an empty directory listing or `EACCES`

### Requirement: Proxy runs as a thread in the snix process

The proxy SHALL run as a thread within the snix process, not a separate process. The thread SHALL start before the builder is forked and SHALL stop after the builder exits.

#### Scenario: Proxy thread starts before fork
- **WHEN** snix prepares to build a derivation
- **THEN** snix SHALL create the child namespace, start the proxy thread, and register the proxy as `file` in the child namespace BEFORE forking the builder process

#### Scenario: Proxy thread stops after builder exits
- **WHEN** the builder process exits (success or failure)
- **THEN** snix SHALL close the scheme socket, causing the proxy thread's event loop to terminate
- **AND** snix SHALL join the proxy thread before proceeding

#### Scenario: Builder crashes
- **WHEN** the builder process is killed or crashes
- **THEN** the scheme socket SHALL be closed by the kernel
- **AND** the proxy thread SHALL detect the closed socket and exit its event loop

### Requirement: Proxy forwards I/O to real filesystem via parent namespace

The proxy thread SHALL access the real filesystem through the parent process's namespace. Since threads share the process namespace and the parent has not called `setns`, the proxy's `std::fs` operations go through the real `file:` scheme.

#### Scenario: Proxy opens a real file
- **WHEN** the proxy receives an `openat` request for an allowed path
- **THEN** the proxy SHALL call `std::fs::File::open()` on the real path
- **AND** the real open SHALL go through the parent's `file:` scheme (real redoxfs)

#### Scenario: Proxy reads from a real file
- **WHEN** the proxy receives a `read` request for an open handle
- **THEN** the proxy SHALL read from the real file descriptor and return the bytes to the builder

### Requirement: Symlinks crossing sandbox boundary are blocked

When a symlink target resolves to a path outside the allow-list, the proxy SHALL reject the access.

#### Scenario: Symlink to allowed path
- **WHEN** `/nix/store/abc-dep-1.0/lib/libfoo.so` is a symlink to `/nix/store/abc-dep-1.0/lib/libfoo.so.1`
- **AND** both are under the allowed prefix `/nix/store/abc-dep-1.0`
- **THEN** the proxy SHALL allow the access

#### Scenario: Symlink to disallowed path
- **WHEN** `/nix/store/abc-dep-1.0/lib/libbar.so` is a symlink to `/nix/store/xyz-other-2.0/lib/libbar.so`
- **AND** `/nix/store/xyz-other-2.0` is NOT on the allow-list
- **THEN** the proxy SHALL return `EACCES` when following the symlink
