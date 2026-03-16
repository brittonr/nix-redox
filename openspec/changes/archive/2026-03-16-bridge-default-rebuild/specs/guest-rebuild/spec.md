## MODIFIED Requirements

### Requirement: Rebuild applies configuration changes to the running system
`snix system rebuild` SHALL evaluate `configuration.nix`, determine the appropriate rebuild path (local or bridge), and activate the result. When the configuration contains only non-package changes (hostname, timezone, DNS, users, etc.), the local path SHALL be used. When the configuration contains package changes, the bridge path SHALL be used if available, otherwise an error is reported.

#### Scenario: Rebuild with hostname change
- **WHEN** `configuration.nix` is edited to change `hostname`
- **AND** `snix system rebuild` is run
- **THEN** `/etc/hostname` contains the new hostname value
- **AND** the current manifest reflects the new hostname
- **AND** a new generation directory exists

#### Scenario: Rebuild with package addition via bridge
- **WHEN** `configuration.nix` is edited to add a package name to the `packages` list
- **AND** the bridge is available (`/scheme/shared/requests` exists)
- **AND** `snix system rebuild` is run
- **THEN** the rebuild routes through the bridge path
- **AND** the package is built by the host, exported, installed, and activated

#### Scenario: Rebuild with package addition without bridge
- **WHEN** `configuration.nix` is edited to add a package name to the `packages` list
- **AND** the bridge is NOT available
- **AND** `--local` is NOT passed
- **THEN** the rebuild reports an error explaining that package changes require the bridge

#### Scenario: Rebuild with nonexistent package via local
- **WHEN** `configuration.nix` lists a package name not in the binary cache
- **AND** `--local` is passed
- **AND** `snix system rebuild` is run
- **THEN** the command reports a warning identifying the missing package
- **AND** the system manifest is NOT modified
