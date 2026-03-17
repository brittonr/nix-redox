## ADDED Requirements

### Requirement: Init script changes detected as boot-affecting
`has_boot_affecting_changes()` SHALL return true when the rebuild config declares services that differ from the current manifest's declared services. A service addition or removal constitutes a boot-affecting change because init scripts are baked into the initfs.

#### Scenario: Adding a new service triggers boot-affecting detection
- **WHEN** configuration.nix declares a `services` list containing `"audiod"`
- **AND** the current manifest's `services.declared` does not contain `"audiod"`
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: Removing a service triggers boot-affecting detection
- **WHEN** configuration.nix declares a `services` list that omits `"smolnetd"`
- **AND** the current manifest's `services.declared` contains `"smolnetd"`
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: Unchanged services do not trigger boot-affecting detection
- **WHEN** configuration.nix declares a `services` list matching the current manifest's declared services
- **THEN** `has_boot_affecting_changes()` returns false (assuming no hardware changes)

#### Scenario: No services field means no service-related boot change
- **WHEN** configuration.nix does not include a `services` field
- **THEN** `has_boot_affecting_changes()` does not consider services (only checks hardware fields)

### Requirement: Boot path changes shown in rebuild summary
`print_changes()` SHALL display boot component store path differences between the current and new manifests when boot paths differ.

#### Scenario: Initfs path change displayed
- **WHEN** the current manifest has `boot.initfs = "/nix/store/old-initfs/boot/initfs"`
- **AND** the merged manifest has `boot.initfs = "/nix/store/new-initfs/boot/initfs"`
- **THEN** the change summary includes a line showing the initfs path change

#### Scenario: No boot changes means no boot lines in summary
- **WHEN** the current and merged manifests have identical `boot` fields
- **THEN** the change summary does not include any boot-related lines

#### Scenario: Boot field absent on either side skips comparison
- **WHEN** either the current or merged manifest has `boot: None`
- **THEN** boot path comparison is skipped without error

### Requirement: All hardware fields individually trigger detection
Each hardware configuration field SHALL independently trigger `has_boot_affecting_changes()` when set, regardless of whether other hardware fields are also set.

#### Scenario: Storage drivers alone triggers detection
- **WHEN** only `hardware.storageDrivers` is set in the config
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: Network drivers alone triggers detection
- **WHEN** only `hardware.networkDrivers` is set in the config
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: Graphics drivers alone triggers detection
- **WHEN** only `hardware.graphicsDrivers` is set in the config
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: Audio drivers alone triggers detection
- **WHEN** only `hardware.audioDrivers` is set in the config
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: USB toggle alone triggers detection
- **WHEN** only `hardware.usbEnabled` is set in the config
- **THEN** `has_boot_affecting_changes()` returns true

#### Scenario: Empty hardware block does not trigger detection
- **WHEN** `hardware` is `Some` but all fields within are `None`
- **THEN** `has_boot_affecting_changes()` returns false
