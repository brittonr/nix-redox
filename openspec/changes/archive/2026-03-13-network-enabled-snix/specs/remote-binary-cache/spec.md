## ADDED Requirements

### Requirement: Unified cache source abstraction

snix SHALL provide a `CacheSource` type that abstracts over local filesystem and remote HTTP binary caches. All package operations (install, search, show, fetch) SHALL work identically regardless of cache source. The cache source SHALL be determined by the `--cache-url` or `--cache-path` argument: URLs starting with `http://` or `https://` indicate a remote cache; filesystem paths indicate a local cache.

#### Scenario: Local cache detection
- **WHEN** user runs `snix install ripgrep --cache-path /nix/cache`
- **THEN** snix SHALL use the local filesystem cache reader

#### Scenario: Remote cache detection
- **WHEN** user runs `snix install ripgrep --cache-url http://10.0.2.2:8080`
- **THEN** snix SHALL use the remote HTTP cache client

#### Scenario: Default cache source
- **WHEN** user runs `snix install ripgrep` without `--cache-url` or `--cache-path`
- **THEN** snix SHALL use the default local cache at `/nix/cache` (or `SNIX_CACHE_PATH` env var)

### Requirement: Remote package index fetching

snix SHALL fetch `packages.json` from a remote binary cache URL via HTTP GET. The remote packages.json format SHALL be identical to the local cache format (version field + packages map with store_path, pname, version, nar_hash, nar_size, file_size). The fetched index SHALL be parsed in memory without writing to disk.

#### Scenario: Fetch remote package index
- **WHEN** snix contacts a remote cache at `http://host:port/`
- **THEN** snix SHALL GET `http://host:port/packages.json` and parse the JSON response

#### Scenario: Remote cache unreachable
- **WHEN** snix cannot connect to the remote cache URL
- **THEN** snix SHALL report a clear error message including the URL and the connection error

#### Scenario: Invalid packages.json
- **WHEN** the remote cache returns malformed JSON for packages.json
- **THEN** snix SHALL report a parse error with the URL

### Requirement: Remote package search

`snix search --cache-url <url>` SHALL fetch the remote packages.json and display matching packages in the same format as local cache search. The optional pattern argument SHALL filter by substring match on package name.

#### Scenario: Search remote cache
- **WHEN** user runs `snix search --cache-url http://10.0.2.2:8080`
- **THEN** snix SHALL list all packages from the remote cache with name, version, and store path

#### Scenario: Search with pattern
- **WHEN** user runs `snix search rip --cache-url http://10.0.2.2:8080`
- **THEN** snix SHALL list only packages whose name contains "rip"

#### Scenario: No matches
- **WHEN** user searches for a pattern with no matches
- **THEN** snix SHALL report "no packages found matching '<pattern>'"

### Requirement: Remote package installation

`snix install <name> --cache-url <url>` SHALL look up the package in the remote packages.json, fetch the narinfo for the store path, download the NAR file, decompress it, verify the hash, extract to `/nix/store/`, register in PathInfoDb, and create profile symlinks. The process SHALL be identical to local cache installation except the I/O source is HTTP.

#### Scenario: Install from remote cache
- **WHEN** user runs `snix install ripgrep --cache-url http://10.0.2.2:8080`
- **THEN** snix SHALL download and install ripgrep, creating a profile symlink in `/nix/var/snix/profiles/default/bin/`

#### Scenario: Package already installed
- **WHEN** user installs a package that is already in the profile
- **THEN** snix SHALL report that the package is already installed

#### Scenario: Package not in remote cache
- **WHEN** user requests a package name not found in the remote packages.json
- **THEN** snix SHALL report "package '<name>' not found in cache"

#### Scenario: NAR hash verification
- **WHEN** snix downloads a NAR from the remote cache
- **THEN** snix SHALL verify the SHA-256 hash matches the narinfo before accepting the extraction

#### Scenario: Hash mismatch
- **WHEN** the downloaded NAR hash does not match the narinfo
- **THEN** snix SHALL delete the partial extraction and report the hash mismatch

### Requirement: Recursive remote dependency fetching

`snix install <name> --cache-url <url> --recursive` SHALL fetch the package and all its transitive dependencies from the remote cache. Dependencies SHALL be discovered from the narinfo `References` field and fetched via BFS traversal. Already-present local store paths SHALL be skipped.

#### Scenario: Install with dependencies
- **WHEN** user runs `snix install myapp --cache-url http://host:port --recursive`
- **THEN** snix SHALL install myapp and all referenced store paths not already present locally

#### Scenario: Dependency already present
- **WHEN** a dependency is already in `/nix/store/` and registered in PathInfoDb
- **THEN** snix SHALL skip downloading it and report "already present"

### Requirement: Remote show command

`snix show <name> --cache-url <url>` SHALL fetch the remote packages.json and display detailed information about the named package (store path, version, NAR size, file size).

#### Scenario: Show remote package info
- **WHEN** user runs `snix show ripgrep --cache-url http://10.0.2.2:8080`
- **THEN** snix SHALL display the package's store path, version, and size information
