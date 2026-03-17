## MODIFIED Requirements

### Requirement: Rebuild applies configuration changes to the running system
`snix system rebuild` SHALL evaluate `configuration.nix`, determine the appropriate rebuild path (local or bridge), and activate the result. When the configuration contains only non-package, non-boot changes (hostname, timezone, DNS, users, etc.), the local path SHALL be used. When the configuration contains package or boot component changes, the bridge path SHALL be used if available, otherwise an error is reported.

The activation plan SHALL display service changes at the semantic level — showing the service name, type, and description rather than raw init script filenames. When a service is added, the plan SHALL show `+ serviceName (type)`. When removed, `- serviceName (type)`.

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

#### Scenario: Activation plan shows service-level diffs
- **WHEN** the old manifest has services `smolnetd` and `dhcpd`
- **AND** the new manifest has services `smolnetd` and `orbital`
- **THEN** the activation plan displays `- dhcpd (daemon)` and `+ orbital (nowait)`
- **AND** does not show raw init script filenames for service changes

#### Scenario: Rebuild with driver change without bridge
- **WHEN** `configuration.nix` is edited to add a storage driver
- **AND** the bridge is NOT available
- **AND** `--local` is NOT passed
- **THEN** the rebuild reports an error explaining that boot component changes require the bridge

#### Scenario: Rebuild with package addition via bridge
- **WHEN** `configuration.nix` is edited to add a package name to the `packages` list
- **AND** the bridge is available (`/scheme/shared/requests` exists)
- **AND** `snix system rebuild` is run
- **THEN** the rebuild routes through the bridge path
- **AND** the package is built by the host, exported, installed, and activated
- **AND** the manifest's `boot` paths are unchanged (packages don't affect boot components)

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
