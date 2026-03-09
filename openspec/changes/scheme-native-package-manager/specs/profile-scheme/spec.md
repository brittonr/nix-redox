## ADDED Requirements

### Requirement: Profile scheme daemon registration

`profiled` SHALL register the `profile` scheme with the Redox kernel by opening `/scheme/profile` with `O_CREAT`. The daemon SHALL enter a request loop processing `Packet` structs and dispatching to handlers for open, read, close, stat, readdir, and write (for profile mutation operations).

#### Scenario: Daemon starts and registers scheme
- **WHEN** `profiled` is started (e.g., by init)
- **THEN** it SHALL register the `profile` scheme and load existing profile mappings from disk

#### Scenario: Scheme already registered
- **WHEN** `profiled` starts and the `profile` scheme is already registered
- **THEN** it SHALL exit with an error message

### Requirement: Union directory view

`profiled` SHALL present a union view of all packages installed in a profile. Opening `profile:default/bin/rg` SHALL resolve through the profile's package mapping to find which store path provides `bin/rg`, then serve the file from that store path. The resolution SHALL NOT use symlinks — it SHALL directly open the underlying file.

#### Scenario: Resolve binary through profile
- **WHEN** a process opens `profile:default/bin/rg`
- **AND** the `default` profile has ripgrep installed with store path `/nix/store/abc...-ripgrep`
- **THEN** `profiled` SHALL serve the content of `/nix/store/abc...-ripgrep/bin/rg`

#### Scenario: Binary not found in any package
- **WHEN** a process opens `profile:default/bin/nonexistent`
- **AND** no package in the profile provides `bin/nonexistent`
- **THEN** `profiled` SHALL return `ENOENT`

#### Scenario: Conflicting binaries
- **WHEN** two packages in the profile both provide `bin/foo`
- **THEN** `profiled` SHALL serve the version from the package installed most recently (last-writer-wins)

#### Scenario: List profile bin directory
- **WHEN** a process reads the directory `profile:default/bin/`
- **THEN** `profiled` SHALL return the union of all `bin/` entries across all packages in the profile, with conflicts resolved by last-installed-wins

### Requirement: Profile mapping table

`profiled` SHALL maintain an in-memory mapping for each profile: a `BTreeMap<String, Vec<ProfileEntry>>` where each `ProfileEntry` contains the package name, store path, and installation timestamp. The mapping SHALL be persisted to `/nix/var/snix/profiles/{name}/mapping.json` on every mutation.

#### Scenario: Add package to profile
- **WHEN** a package is installed into a profile (via `snix install` or a write to `profile:default/.control`)
- **THEN** `profiled` SHALL add the entry to the in-memory mapping and persist to disk

#### Scenario: Remove package from profile
- **WHEN** a package is removed from a profile
- **THEN** `profiled` SHALL remove the entry from the in-memory mapping and persist to disk

#### Scenario: Load mapping on startup
- **WHEN** `profiled` starts
- **THEN** it SHALL load `/nix/var/snix/profiles/{name}/mapping.json` for each profile directory found

#### Scenario: Persist mapping on mutation
- **WHEN** the mapping changes (add or remove)
- **THEN** `profiled` SHALL atomically write the updated mapping (write to temp file, rename)

### Requirement: Instant package add/remove

Adding or removing a package from a profile SHALL NOT involve creating or deleting symlinks. The operation SHALL update the in-memory mapping table and persist the mapping file. The time complexity SHALL be O(1) for add and O(n) for remove where n is the number of packages (to find the entry), not O(files) where files is the total number of files across all packages.

#### Scenario: Install updates mapping only
- **WHEN** `snix install ripgrep` delegates to `profiled`
- **THEN** `profiled` SHALL add `("ripgrep", "/nix/store/abc...-ripgrep", timestamp)` to the mapping
- **AND** SHALL NOT create any symlinks in the filesystem

#### Scenario: Remove updates mapping only
- **WHEN** `snix remove ripgrep` delegates to `profiled`
- **THEN** `profiled` SHALL remove the ripgrep entry from the mapping
- **AND** SHALL NOT delete any files from the filesystem

#### Scenario: Crash during install
- **WHEN** `profiled` crashes between updating the in-memory mapping and persisting to disk
- **THEN** on restart, the mapping SHALL reflect the last successfully persisted state (atomic write ensures no partial states)

### Requirement: Profile directory traversal

`profiled` SHALL support opening paths at any depth within the profile namespace. The path `profile:{name}/{subpath}` SHALL search each package's store path for `{subpath}` in reverse installation order (most recent first).

#### Scenario: Access library file
- **WHEN** a process opens `profile:default/lib/libfoo.so`
- **AND** package `foo` provides `/nix/store/abc...-foo/lib/libfoo.so`
- **THEN** `profiled` SHALL serve that file

#### Scenario: Access share directory
- **WHEN** a process opens `profile:default/share/man/man1/rg.1`
- **THEN** `profiled` SHALL resolve through all packages to find one providing `share/man/man1/rg.1`

#### Scenario: List subdirectory
- **WHEN** a process reads directory `profile:default/share/man/man1/`
- **THEN** `profiled` SHALL return the union of `share/man/man1/` entries across all packages

### Requirement: Multiple profile support

`profiled` SHALL support multiple named profiles. The profile name is the first path component: `profile:default/...`, `profile:dev/...`, `profile:system/...`. Each profile has its own independent mapping table and mapping file.

#### Scenario: Access default profile
- **WHEN** a process opens `profile:default/bin/rg`
- **THEN** `profiled` SHALL resolve using the `default` profile's mapping

#### Scenario: Access named profile
- **WHEN** a process opens `profile:dev/bin/cargo`
- **THEN** `profiled` SHALL resolve using the `dev` profile's mapping

#### Scenario: List profiles
- **WHEN** a process reads directory `profile:`
- **THEN** `profiled` SHALL return the list of all profile names

### Requirement: Control interface for profile mutations

`profiled` SHALL expose a control interface at `profile:{name}/.control` for adding and removing packages. Writing a JSON command to this path SHALL trigger the corresponding mapping mutation.

#### Scenario: Add package via control interface
- **WHEN** a process writes `{"action": "add", "name": "ripgrep", "storePath": "/nix/store/abc...-ripgrep"}` to `profile:default/.control`
- **THEN** `profiled` SHALL add ripgrep to the default profile's mapping

#### Scenario: Remove package via control interface
- **WHEN** a process writes `{"action": "remove", "name": "ripgrep"}` to `profile:default/.control`
- **THEN** `profiled` SHALL remove ripgrep from the default profile's mapping

#### Scenario: snix delegates to control interface
- **WHEN** `snix install ripgrep` detects that `profiled` is running
- **THEN** it SHALL write the add command to `profile:default/.control` instead of managing symlinks

### Requirement: Graceful fallback when daemon is not running

When `profiled` is not running, snix SHALL fall back to the current symlink-based profile management at `/nix/var/snix/profiles/default/bin/`.

#### Scenario: profiled not running, snix install
- **WHEN** `snix install ripgrep` runs and `profiled` is not running
- **THEN** snix SHALL create symlinks in `/nix/var/snix/profiles/default/bin/` as it does today

#### Scenario: profiled not running, PATH resolution
- **WHEN** `profiled` is not running and a user has `/nix/var/snix/profiles/default/bin` in PATH
- **THEN** symlink-based profile binaries SHALL work normally via the `file:` scheme
