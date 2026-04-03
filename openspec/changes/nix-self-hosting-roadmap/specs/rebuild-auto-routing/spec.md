## MODIFIED Requirements

### Requirement: Auto-route to bridge when packages changed and bridge available
`snix system rebuild` SHALL automatically use the bridge path when the parsed configuration contains package changes and `/scheme/shared/requests` is a directory. When the bridge is not available and the configuration contains package changes, the rebuild SHALL attempt to resolve packages from the remote cache (if `--cache-url` provided) or the local cache, rather than failing immediately.

#### Scenario: Bridge available with package changes
- **WHEN** configuration.nix adds a new package
- **AND** `/scheme/shared/requests` exists (bridge is connected)
- **THEN** the rebuild routes through the bridge for package resolution

#### Scenario: No bridge, remote cache available
- **WHEN** configuration.nix adds a new package
- **AND** the bridge is not available
- **AND** `--cache-url` is provided
- **THEN** the rebuild fetches the package from the remote cache

#### Scenario: No bridge, no remote cache, package in local cache
- **WHEN** configuration.nix adds a package that exists in `/nix/cache`
- **AND** neither bridge nor `--cache-url` is available
- **THEN** the rebuild resolves from the local cache

#### Scenario: No bridge, no cache, source available
- **WHEN** configuration.nix specifies `packageSources` and `--source` is given
- **AND** neither bridge nor cache has the package
- **THEN** the rebuild builds the package from source
