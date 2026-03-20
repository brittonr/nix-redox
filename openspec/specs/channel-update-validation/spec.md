## ADDED Requirements

### Requirement: Channel registration creates local state
`snix channel add <name> <url>` SHALL create `/nix/var/snix/channels/<name>/url` containing the channel URL. `snix channel list` SHALL display the registered channel with its URL and fetch status.

#### Scenario: Add and list a channel
- **WHEN** `snix channel add test-channel http://10.0.2.2:18080` is run inside the Redox VM
- **THEN** `/nix/var/snix/channels/test-channel/url` exists with content `http://10.0.2.2:18080`
- **AND** `snix channel list` output contains `test-channel`

### Requirement: Channel update fetches manifest over HTTP
`snix channel update <name>` SHALL HTTP GET `<url>/manifest.json`, validate it as JSON, and save it to `/nix/var/snix/channels/<name>/manifest.json`. It SHALL also write a `last-fetched` timestamp.

#### Scenario: Update a channel from HTTP cache
- **WHEN** `snix channel update test-channel` is run and the host serves a valid manifest.json at `http://10.0.2.2:18080/manifest.json`
- **THEN** `/nix/var/snix/channels/test-channel/manifest.json` exists and contains valid JSON
- **AND** `/nix/var/snix/channels/test-channel/last-fetched` is non-empty

#### Scenario: Update a channel with unreachable URL
- **WHEN** `snix channel update bad-channel` is run and the URL is unreachable
- **THEN** the command exits with a non-zero status

### Requirement: System upgrade creates a new generation from channel manifest
`snix system upgrade --yes` SHALL fetch the channel manifest, compare with the current system, fetch any missing packages from the binary cache, and call `system switch` to create a new generation.

#### Scenario: Upgrade with a new package in channel manifest
- **WHEN** the channel manifest contains a package not in the current system
- **AND** the binary cache serves that package's NAR
- **AND** `snix system upgrade --yes` is run
- **THEN** a new generation directory is created under `/etc/redox-system/generations/`
- **AND** the new generation's manifest.json contains the new package
- **AND** the current manifest (`/etc/redox-system/manifest.json`) is updated

### Requirement: Idempotent upgrade reports no changes
When the current system already matches the channel manifest, `snix system upgrade` SHALL report "already up to date" and not create a new generation.

#### Scenario: Second upgrade is a no-op
- **WHEN** `snix system upgrade --yes` succeeded on the first run
- **AND** `snix system upgrade --yes` is run a second time without manifest changes
- **THEN** the output contains "already up to date"
- **AND** no additional generation directory is created

### Requirement: VM test profile exercises full channel pipeline
A test profile (`channel-update-test.nix`) SHALL boot Redox with networking, run the channel add → update → upgrade → verify → idempotent-upgrade pipeline, and emit `FUNC_TEST` results to serial output.

#### Scenario: All channel tests pass in VM
- **WHEN** `nix run .#channel-update-test` is executed
- **THEN** serial output contains `FUNC_TESTS_START` followed by PASS results for each test step
- **AND** serial output ends with `FUNC_TESTS_COMPLETE`
- **AND** zero FAIL results are emitted

### Requirement: Channel upgrade test serves a modified manifest
The test infrastructure SHALL serve a manifest over HTTP that differs from the on-disk manifest by containing at least one additional package. The binary cache SHALL contain the NAR for that package so `fetch_upgrade_packages` can retrieve it.

#### Scenario: Channel manifest has extra package
- **WHEN** the HTTP server starts with the test cache
- **THEN** `manifest.json` at the cache URL contains one more package entry than the system's `/etc/redox-system/manifest.json`
- **AND** the corresponding narinfo and NAR files are present in the cache
