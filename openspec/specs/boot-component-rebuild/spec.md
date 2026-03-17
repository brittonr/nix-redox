## ADDED Requirements

### Requirement: Bridge rebuild detects boot-affecting config changes
`snix system rebuild` SHALL detect when configuration changes affect boot components (drivers, init scripts, boot settings) and route those changes through the bridge for host-side rebuilding.

#### Scenario: Driver addition triggers initfs rebuild via bridge
- **WHEN** `configuration.nix` adds a storage driver to `hardware.storageDrivers`
- **AND** `snix system rebuild` is run
- **AND** the bridge is available
- **THEN** the bridge request indicates boot components need rebuilding
- **AND** a new initfs is built on the host with the added driver
- **AND** the new initfs store path is installed on the guest rootfs

#### Scenario: Config-only change without boot impact skips boot rebuild
- **WHEN** `configuration.nix` changes only `hostname`
- **AND** `snix system rebuild` is run
- **THEN** no boot component rebuild is requested
- **AND** the manifest's `boot` paths remain unchanged

#### Scenario: Boot-affecting change without bridge reports error
- **WHEN** `configuration.nix` adds a new driver
- **AND** the bridge is NOT available
- **AND** `snix system rebuild` is run
- **THEN** the command reports an error explaining boot component changes require the bridge
- **AND** the system manifest is NOT modified

### Requirement: Rebuilt boot components delivered through binary cache
Boot component derivations (kernel, initfs) rebuilt on the host SHALL be exported to the guest through the same binary cache pipeline used for packages.

#### Scenario: New initfs appears as store path after bridge rebuild
- **WHEN** the bridge rebuilds an initfs due to driver changes
- **THEN** the initfs derivation is exported as a NAR to the binary cache
- **AND** the guest installs it to `/nix/store/` on the rootfs
- **AND** the new generation's manifest `boot.initfs` points to the new store path

### Requirement: Boot change detection covers all boot-affecting fields
The rebuild system SHALL treat the following configuration changes as boot-affecting: `hardware.storageDrivers`, `hardware.networkDrivers`, `hardware.graphicsDrivers`, `hardware.audioDrivers`, `hardware.usbEnabled`, and init script additions or removals.

#### Scenario: Network driver change detected as boot-affecting
- **WHEN** `configuration.nix` changes `hardware.networkDrivers`
- **THEN** `has_boot_config_changed()` returns true
- **AND** the rebuild requests boot component rebuilding

#### Scenario: USB toggle detected as boot-affecting
- **WHEN** `configuration.nix` changes `hardware.usbEnabled` from false to true
- **THEN** `has_boot_config_changed()` returns true
