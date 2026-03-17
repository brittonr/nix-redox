## MODIFIED Requirements

### Requirement: Rebuild applies configuration changes to the running system
`snix system rebuild` SHALL evaluate `configuration.nix`, determine the appropriate rebuild path (local or bridge), and activate the result. When the configuration contains only non-package, non-boot changes (hostname, timezone, DNS, users, etc.), the local path SHALL be used. When the configuration contains package or boot component changes, the bridge path SHALL be used if available, otherwise an error is reported.

The activation plan SHALL display service changes at the semantic level — showing the service name, type, and description rather than raw init script filenames. When a service is added, the plan SHALL show `+ serviceName (type)`. When removed, `- serviceName (type)`.

#### Scenario: Activation plan shows service-level diffs
- **WHEN** the old manifest has services `smolnetd` and `dhcpd`
- **AND** the new manifest has services `smolnetd` and `orbital`
- **THEN** the activation plan's `services_removed` contains `dhcpd` with its type
- **AND** the activation plan's `services_added` contains `orbital` with its type
- **AND** `smolnetd` is in neither added nor removed

#### Scenario: Reboot recommended after boot path change
- **WHEN** the old manifest has `boot.initfs = "/nix/store/old-initfs/boot/initfs"`
- **AND** the new manifest has `boot.initfs = "/nix/store/new-initfs/boot/initfs"`
- **AND** activation runs
- **THEN** `reboot_recommended` is true in the activation result

#### Scenario: Rebuild with nonexistent package via local
- **WHEN** `configuration.nix` lists a package name not in the binary cache index
- **AND** the package resolves with an empty store path
- **AND** `merge_config` is called with the unresolved package
- **THEN** only boot-essential packages from the current manifest are preserved
- **AND** the unresolved package (empty store path) is included in the merged manifest's package list

#### Scenario: Rebuild with hostname change
- **WHEN** `configuration.nix` is edited to change `hostname`
- **AND** `snix system rebuild` is run
- **THEN** `/etc/hostname` contains the new hostname value
- **AND** the current manifest reflects the new hostname
- **AND** a new generation directory exists
- **AND** the manifest's `boot` paths are unchanged

#### Scenario: Rebuild with driver change without bridge
- **WHEN** `configuration.nix` is edited to add a storage driver
- **AND** the bridge is NOT available
- **AND** `--local` is NOT passed
- **THEN** the rebuild reports an error explaining that boot component changes require the bridge

#### Scenario: Auto-route allows local path for config-only changes
- **WHEN** `configuration.nix` changes only `hostname` and `timezone`
- **AND** `snix system rebuild` is run without `--bridge` or `--local`
- **THEN** the auto-router uses the local path
- **AND** no bridge communication occurs
