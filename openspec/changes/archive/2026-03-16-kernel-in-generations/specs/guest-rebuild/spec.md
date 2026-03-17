## MODIFIED Requirements

### Requirement: Rebuild applies configuration changes to the running system
`snix system rebuild` SHALL evaluate `configuration.nix`, determine the appropriate rebuild path (local or bridge), and activate the result. When the configuration contains only non-package, non-boot changes (hostname, timezone, DNS, users, etc.), the local path SHALL be used. When the configuration contains package or boot component changes, the bridge path SHALL be used if available, otherwise an error is reported.

#### Scenario: Rebuild with hostname change
- **WHEN** `configuration.nix` is edited to change `hostname`
- **AND** `snix system rebuild` is run
- **THEN** `/etc/hostname` contains the new hostname value
- **AND** the current manifest reflects the new hostname
- **AND** a new generation directory exists
- **AND** the manifest's `boot` paths are unchanged

#### Scenario: Rebuild with driver change via bridge
- **WHEN** `configuration.nix` is edited to add a storage driver
- **AND** the bridge is available
- **AND** `snix system rebuild` is run
- **THEN** the rebuild routes through the bridge path
- **AND** a new initfs is built on the host and installed on the guest
- **AND** `/boot/initfs` is updated with the new initfs
- **AND** the new generation's `boot.initfs` path differs from the previous generation
- **AND** a "reboot recommended" message is displayed

#### Scenario: Rebuild with driver change without bridge
- **WHEN** `configuration.nix` is edited to add a storage driver
- **AND** the bridge is NOT available
- **AND** `--local` is NOT passed
- **THEN** the rebuild reports an error explaining that boot component changes require the bridge

#### Scenario: Rebuild with package addition via bridge
- **WHEN** `configuration.nix` is edited to add a package name to the `packages` list
- **AND** the bridge is available
- **AND** `snix system rebuild` is run
- **THEN** the rebuild routes through the bridge path
- **AND** the package is built by the host, exported, installed, and activated
- **AND** the manifest's `boot` paths are unchanged (packages don't affect boot components)

### Requirement: Rebuild creates a generation before applying changes
`snix system rebuild` SHALL save the current system state as a generation before activating the new configuration. The saved generation SHALL include boot component store paths.

#### Scenario: Rebuild saves boot paths in pre-rebuild generation
- **WHEN** the system has `boot.kernel` = `/nix/store/abc-kernel` in the active manifest
- **AND** `snix system rebuild` is run successfully
- **THEN** the pre-rebuild generation's saved manifest contains `boot.kernel` = `/nix/store/abc-kernel`
- **AND** rolling back to that generation restores the original boot components

### Requirement: Rebuild auto-routing includes boot changes
The auto-routing logic SHALL treat boot-affecting configuration changes (driver lists, init scripts) the same as package changes — requiring the bridge path.

#### Scenario: Auto-route detects driver change as bridge-required
- **WHEN** `configuration.nix` changes only `hardware.storageDrivers` (no package changes)
- **AND** `snix system rebuild` is run without `--bridge` or `--local`
- **THEN** the auto-router detects the boot-affecting change
- **AND** routes the rebuild through the bridge path

#### Scenario: Auto-route allows local path for config-only changes
- **WHEN** `configuration.nix` changes only `hostname` and `timezone`
- **AND** `snix system rebuild` is run without `--bridge` or `--local`
- **THEN** the auto-router uses the local path
- **AND** no bridge communication occurs
