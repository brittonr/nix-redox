## ADDED Requirements

### Requirement: Proxy handles full I/O round-trip for builder processes

The `BuildFsProxy` event loop SHALL handle the complete lifecycle of file operations from builder processes: open, read, write, seek, fstat, fpath, getdents, and close. The proxy SHALL forward permitted operations to the real filesystem via the parent process's namespace and return results through the scheme socket. The proxy SHALL handle concurrent requests from multiple child processes (cargo→rustc→cc→lld) queued at the scheme socket.

#### Scenario: Builder reads a declared input file
- **WHEN** a builder opens and reads `/nix/store/abc-dep/lib/libfoo.so` (a declared input)
- **THEN** the proxy SHALL open the real file in the parent namespace
- **AND** return the file contents through the scheme socket
- **AND** the builder SHALL receive identical bytes to the real file

#### Scenario: Builder writes to $out with nested directories
- **WHEN** a builder calls `open("/nix/store/out-hash/lib/rustlib/target/lib/libcore.rlib", O_CREAT|O_WRONLY)`
- **AND** the intermediate directories do not exist
- **THEN** the proxy SHALL create the parent directories recursively
- **AND** create and open the file for writing
- **AND** return a valid handle to the builder

#### Scenario: Builder reads back its own output
- **WHEN** a builder writes a file to `$out/bin/hello` and then reads it back
- **THEN** the proxy SHALL return the same bytes that were written

#### Scenario: Multiple child processes issue concurrent requests
- **WHEN** cargo spawns 4 rustc processes that all perform file I/O
- **THEN** the proxy SHALL process requests sequentially via the scheme socket
- **AND** no request SHALL be dropped or corrupted

#### Scenario: Builder closes file handle
- **WHEN** a builder closes a proxied file descriptor
- **THEN** the proxy SHALL close the corresponding real file descriptor
- **AND** remove the handle from its internal table

### Requirement: Proxy enforces read-only access on input store paths

The proxy SHALL deny write operations to paths that are on the allow-list as read-only (input store paths). Only `$out` and `$TMPDIR` SHALL be writable.

#### Scenario: Builder attempts to write to an input store path
- **WHEN** a builder calls `open("/nix/store/abc-dep/lib/libfoo.so", O_WRONLY)`
- **AND** `/nix/store/abc-dep` is a declared input (read-only)
- **THEN** the proxy SHALL return `EACCES`

#### Scenario: Builder reads from input store path
- **WHEN** a builder calls `open("/nix/store/abc-dep/lib/libfoo.so", O_RDONLY)`
- **AND** `/nix/store/abc-dep` is a declared input (read-only)
- **THEN** the proxy SHALL open the file and return a valid handle

#### Scenario: Builder truncates input store path
- **WHEN** a builder calls `open("/nix/store/abc-dep/lib/libfoo.so", O_TRUNC)`
- **AND** `/nix/store/abc-dep` is a declared input (read-only)
- **THEN** the proxy SHALL return `EACCES`

### Requirement: Proxy denies access to undeclared paths

The proxy SHALL return `EACCES` for any path not on the allow-list. This includes paths outside `/nix/store/`, undeclared store paths, and system files.

#### Scenario: Builder reads /etc/passwd
- **WHEN** a builder calls `open("/etc/passwd", O_RDONLY)`
- **THEN** the proxy SHALL return `EACCES`

#### Scenario: Builder reads undeclared store path
- **WHEN** a builder calls `open("/nix/store/xyz-other/bin/foo", O_RDONLY)`
- **AND** `xyz-other` is NOT in the derivation's inputs
- **THEN** the proxy SHALL return `EACCES`

#### Scenario: Builder attempts path traversal via ..
- **WHEN** a builder calls `open("/nix/store/abc-dep/../../etc/passwd", O_RDONLY)`
- **THEN** the proxy SHALL resolve `..` components to `/etc/passwd`
- **AND** return `EACCES` (not on allow-list)

#### Scenario: Builder reads $HOME
- **WHEN** a builder calls `open("/home/user/.ssh/id_rsa", O_RDONLY)`
- **THEN** the proxy SHALL return `EACCES`

### Requirement: Proxy provides filtered directory listings

The proxy's `getdents` implementation SHALL return only entries that are on the allow-list or are ancestors of allowed paths. Listing `/nix/store/` SHALL show only the declared input store paths and the output store path, not all store paths on disk.

#### Scenario: Listing /nix/store shows only declared paths
- **WHEN** a builder calls `getdents` on `/nix/store/`
- **AND** the allow-list contains `/nix/store/abc-dep` and `/nix/store/out-hash`
- **AND** the real `/nix/store/` has 50 other entries
- **THEN** the proxy SHALL return only `abc-dep` and `out-hash`

#### Scenario: Listing / shows nix as navigable
- **WHEN** a builder calls `getdents` on `/`
- **AND** the allow-list contains paths under `/nix/store/`
- **THEN** the proxy SHALL include `nix` in the directory listing

#### Scenario: Listing allowed directory shows all children
- **WHEN** a builder calls `getdents` on `/nix/store/abc-dep/lib/`
- **AND** `/nix/store/abc-dep` is on the allow-list
- **THEN** the proxy SHALL return ALL entries in the real directory (no filtering within allowed prefixes)

### Requirement: Proxy handles open flag translation

The proxy SHALL correctly interpret Redox-specific open flags. `O_RDONLY` is `0x10000` on Redox (not 0). `O_CREAT` is `0x02000000`. The proxy SHALL determine write intent by checking `O_WRONLY`, `O_RDWR`, `O_CREAT`, and `O_TRUNC` against the Redox `syscall::flag` constants.

#### Scenario: O_RDONLY opens file for reading
- **WHEN** a builder opens a file with flags containing only `O_RDONLY` (0x10000)
- **THEN** the proxy SHALL open the real file read-only

#### Scenario: O_CREAT on new file in $out
- **WHEN** a builder opens a non-existent file with `O_CREAT` in `$out`
- **THEN** the proxy SHALL create the file and return a writable handle

#### Scenario: O_RDWR opens file for reading and writing
- **WHEN** a builder opens a file in `$out` with `O_RDWR`
- **THEN** the proxy SHALL open the real file with both read and write access

### Requirement: Proxy symlink resolution checks both paths

When a builder opens a path that contains symlinks, the proxy SHALL check both the literal requested path AND the resolved target path against the allow-list. A symlink under an allowed prefix that points outside the allow-list SHALL be denied.

#### Scenario: Symlink within allowed prefix
- **WHEN** a builder opens `/nix/store/abc-dep/lib/libfoo.so`
- **AND** `libfoo.so` is a symlink to `libfoo.so.1.0` in the same directory
- **THEN** the proxy SHALL allow the access (both paths under the same allowed prefix)

#### Scenario: Symlink escaping to disallowed path
- **WHEN** a builder opens `/nix/store/abc-dep/lib/evil.so`
- **AND** `evil.so` is a symlink to `/etc/shadow`
- **THEN** the proxy SHALL deny the access (`/etc/shadow` not on allow-list)

### Requirement: Proxy lifecycle matches builder lifetime

The proxy thread SHALL start before the builder process is forked and SHALL shut down after the builder exits. `local_build.rs` SHALL call `proxy.shutdown()` after collecting the builder's exit status, even on build failure.

#### Scenario: Proxy starts before builder fork
- **WHEN** `local_build.rs` sets up a sandboxed build
- **THEN** the proxy SHALL be running and registered as `file:` in the child namespace BEFORE `Command::spawn()` is called

#### Scenario: Proxy shuts down after builder exits
- **WHEN** the builder process exits (success or failure)
- **THEN** `local_build.rs` SHALL call `proxy.shutdown()`
- **AND** the proxy thread SHALL join within 5 seconds

#### Scenario: Proxy handles builder crash
- **WHEN** the builder process crashes (SIGSEGV, SIGABRT)
- **THEN** the proxy SHALL continue running until `shutdown()` is called
- **AND** any pending scheme requests SHALL be drained

### Requirement: Round-trip I/O validation in proxy_namespace_test

The `proxy_namespace_test.rs` binary SHALL include tests that exercise the full I/O path through the proxy: write a file via the proxied `file:` scheme, read it back, verify contents. The test SHALL run inside a Redox VM and emit `PASS`/`FAIL` results.

#### Scenario: Write-read round-trip
- **WHEN** the test writes "hello proxy" to a file in `$TMPDIR` through the proxy
- **AND** reads the file back through the proxy
- **THEN** the read content SHALL equal "hello proxy"

#### Scenario: Permission denial round-trip
- **WHEN** the test attempts to open `/etc/passwd` through the proxy
- **THEN** the open SHALL fail with `EACCES`

#### Scenario: Directory listing round-trip
- **WHEN** the test creates files in `$TMPDIR` and calls `getdents` on `$TMPDIR`
- **THEN** the listing SHALL include the created files

### Requirement: Self-hosting test suite passes with proxy enabled

The full self-hosting test suite (62 tests) SHALL pass with `sandbox = true` in the snix configuration. This validates the proxy under real cargo build workloads with deep process hierarchies and high crate counts.

#### Scenario: 193-crate snix build with proxy
- **WHEN** `snix build .#snix-redox` runs inside the VM with the proxy enabled
- **THEN** the build SHALL complete successfully
- **AND** the output binary SHALL be functional

#### Scenario: 33-crate ripgrep build with proxy
- **WHEN** `snix build .#ripgrep` runs inside the VM with the proxy enabled
- **THEN** the build SHALL complete successfully
- **AND** `rg --version` SHALL produce output

#### Scenario: Proc-macro crate compilation with proxy
- **WHEN** a build includes proc-macro crates (serde_derive, thiserror)
- **THEN** the proxy SHALL allow reading the proc-macro output directory
- **AND** the proc-macro SHALL load and execute correctly

#### Scenario: Build scripts with proxy
- **WHEN** a build script (build.rs) writes to `$OUT_DIR` and reads source files
- **THEN** the proxy SHALL allow writes to `$OUT_DIR` (under `$TMPDIR`)
- **AND** reads from declared input sources
