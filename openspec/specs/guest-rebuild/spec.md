## ADDED Requirements

### Requirement: Show current configuration without modifying system
`snix system show-config` SHALL parse and display the current `/etc/redox-system/configuration.nix` without modifying any system state.

#### Scenario: Show config on a booted system
- **WHEN** a Redox system has booted with a valid `configuration.nix` in `/etc/redox-system/`
- **THEN** `snix system show-config` exits successfully and outputs parseable configuration values

### Requirement: Dry-run rebuild previews changes without applying
`snix system rebuild --dry-run` SHALL evaluate `configuration.nix`, resolve packages, diff against the current manifest, and display planned changes without writing any files.

#### Scenario: Dry-run with unchanged config
- **WHEN** `snix system rebuild --dry-run` is run and `configuration.nix` matches the current manifest
- **THEN** the command exits successfully and reports no changes

#### Scenario: Dry-run with hostname change
- **WHEN** `configuration.nix` has been modified to set a different hostname
- **AND** `snix system rebuild --dry-run` is run
- **THEN** the command shows the hostname change without modifying `/etc/hostname` or the manifest

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

### Requirement: Rebuild creates a generation before applying changes
`snix system rebuild` SHALL save the current system state as a generation before activating the new configuration.

#### Scenario: First rebuild creates generation for original state
- **WHEN** the system boots with generation ID 1 and no prior generations directory
- **AND** `snix system rebuild` is run successfully
- **THEN** generation 1 (the pre-rebuild state) is saved in `/etc/redox-system/generations/1/manifest.json`
- **AND** the new state is saved as generation 2

### Requirement: Configuration.nix exists on booted systems
The build system SHALL embed a default `configuration.nix` in `/etc/redox-system/` reflecting the profile's declared configuration.

#### Scenario: Development profile has configuration.nix
- **WHEN** a development-profile image boots
- **THEN** `/etc/redox-system/configuration.nix` exists and contains valid Nix syntax
