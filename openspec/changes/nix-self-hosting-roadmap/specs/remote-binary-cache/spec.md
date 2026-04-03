## MODIFIED Requirements

### Requirement: Unified cache source abstraction

snix SHALL provide a `CacheSource` type that abstracts over local filesystem and remote HTTP binary caches. All package operations (install, search, show, fetch) SHALL work identically regardless of cache source. The cache source SHALL be determined by the `--cache-url` or `--cache-path` argument: URLs starting with `http://` or `https://` indicate a remote cache; filesystem paths indicate a local cache.

The Remote variant SHALL use minreq for HTTP/1.1 requests. Connection errors, HTTP 4xx/5xx responses, and timeouts SHALL produce user-facing error messages that include the URL and status code.

#### Scenario: Local cache detection
- **WHEN** user runs `snix install ripgrep --cache-path /nix/cache`
- **THEN** snix SHALL use the local filesystem cache reader

#### Scenario: Remote cache detection
- **WHEN** user runs `snix install ripgrep --cache-url http://10.0.2.2:8080`
- **THEN** snix SHALL use the remote HTTP cache client

#### Scenario: Default cache source
- **WHEN** user runs `snix install ripgrep` without `--cache-url` or `--cache-path`
- **THEN** snix SHALL use the default local cache at `/nix/cache`

#### Scenario: Remote cache connection failure
- **WHEN** snix cannot connect to the remote cache URL
- **THEN** snix SHALL report an error including the URL and the connection error
- **AND** snix SHALL NOT fall back to local cache silently

### Requirement: Remote package index fetching

snix SHALL fetch `packages.json` from a remote binary cache URL via HTTP GET. The remote `packages.json` format SHALL be identical to the local cache format. The fetched index SHALL be parsed in memory without writing to disk.

#### Scenario: Fetch remote package index
- **WHEN** snix contacts a remote cache at `http://host:port/`
- **THEN** snix SHALL GET `http://host:port/packages.json` and parse the JSON response

#### Scenario: Remote index parse failure
- **WHEN** the remote `packages.json` response is not valid JSON
- **THEN** snix SHALL report a parse error with the URL and the first 200 bytes of the response body

### Requirement: Remote NAR fetching and extraction

snix SHALL download NAR files from the remote cache via HTTP GET and extract them to `/nix/store/`. The NAR URL SHALL be derived from the narinfo's `URL` field, resolved relative to the cache base URL. After download, snix SHALL verify the NAR hash matches the narinfo's `NarHash` before extraction.

#### Scenario: Fetch and extract a NAR
- **WHEN** snix resolves `ripgrep` from the remote index
- **AND** the narinfo indicates `URL: abc123.nar.zst`
- **THEN** snix SHALL GET `http://host:port/abc123.nar.zst`
- **AND** verify the SHA-256 hash matches `NarHash`
- **AND** extract the contents to `/nix/store/abc...-ripgrep/`

#### Scenario: NAR hash mismatch
- **WHEN** the downloaded NAR's hash does not match the narinfo's `NarHash`
- **THEN** snix SHALL discard the download and report a hash mismatch error
- **AND** the store path SHALL NOT be created

### Requirement: Remote install end-to-end

`snix install <package> --cache-url <url>` SHALL resolve the package from the remote index, download the NAR, extract to the store, and link into the profile — identical to local install except the fetch is over HTTP.

#### Scenario: Install from remote cache
- **WHEN** user runs `snix install ripgrep --cache-url http://10.0.2.2:8080`
- **AND** the remote cache has ripgrep
- **THEN** ripgrep is installed and `rg --version` works
