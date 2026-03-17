## MODIFIED Requirements

### Requirement: Boot-time generation activation
The init system SHALL activate the default generation's manifest after root mount and before userspace entry, restoring the generation's package profile, config files, and boot components.

#### Scenario: Boot with default-generation marker set
- **WHEN** `/etc/redox-system/boot-default` contains `3`
- **AND** generation 3 exists in `/etc/redox-system/generations/3/manifest.json`
- **AND** generation 3's manifest has `boot.kernel` and `boot.initfs` paths
- **AND** the system boots
- **THEN** `/nix/system/profile/bin/` reflects generation 3's package set
- **AND** `/etc/hostname` reflects generation 3's hostname
- **AND** `/boot/kernel` contains the bytes from generation 3's `boot.kernel` store path
- **AND** `/boot/initfs` contains the bytes from generation 3's `boot.initfs` store path

#### Scenario: Boot activation with v1 generation (no boot paths)
- **WHEN** `/etc/redox-system/boot-default` references a generation with a v1 manifest
- **AND** the v1 manifest has no `boot` section
- **AND** the system boots
- **THEN** package profile and config files are activated normally
- **AND** `/boot/kernel` and `/boot/initfs` are NOT modified
- **AND** no error or warning is logged about missing boot paths

#### Scenario: Boot without default-generation marker
- **WHEN** `/etc/redox-system/boot-default` does not exist
- **AND** the system boots
- **THEN** the system boots with the current on-disk manifest unchanged
- **AND** no generation activation occurs during init

#### Scenario: Boot with invalid generation reference
- **WHEN** `/etc/redox-system/boot-default` contains `99`
- **AND** generation 99 does not exist
- **AND** the system boots
- **THEN** a warning is logged to serial output
- **AND** the system boots with the current on-disk manifest
- **AND** userspace entry proceeds normally

### Requirement: activate-boot subcommand
`snix system activate-boot` SHALL activate a generation's manifest without creating a new generation entry, including restoring boot components when the generation's manifest contains boot paths.

#### Scenario: Activate a stored generation with boot paths
- **WHEN** `snix system activate-boot --generation 3` is run
- **AND** generation 3 has boot paths in its manifest
- **AND** the boot paths differ from the current `/boot/` contents
- **THEN** `/boot/kernel` is updated from generation 3's `boot.kernel` store path
- **AND** `/boot/initfs` is updated from generation 3's `boot.initfs` store path
- **AND** a "reboot recommended for boot component changes" message is logged

#### Scenario: Activate generation with same boot paths as current
- **WHEN** `snix system activate-boot --generation 2` is run
- **AND** generation 2 has the same `boot.kernel` path as the current manifest
- **THEN** `/boot/kernel` is NOT rewritten (no unnecessary I/O)
- **AND** no reboot recommendation is logged for boot components

#### Scenario: Activate generation with missing boot store path
- **WHEN** `snix system activate-boot --generation 2` is run
- **AND** generation 2's `boot.kernel` references a store path that was garbage collected
- **THEN** a warning is logged identifying the missing store path
- **AND** `/boot/kernel` is NOT modified
- **AND** package profile and config activation proceed normally

### Requirement: Init script positioning
The generation activation init script SHALL run after root mount (`50_rootfs`) and before userspace entry (`90_exit_initfs`).

#### Scenario: Activation occurs after root is mounted
- **WHEN** the init sequence reaches `85_generation_select`
- **THEN** the root filesystem is mounted and `/etc/redox-system/generations/` is accessible
- **AND** `/bin/snix` is executable

#### Scenario: Activation completes before PATH is set
- **WHEN** `90_exit_initfs` runs
- **THEN** the profile at `/nix/system/profile/bin/` already reflects the activated generation
- **AND** PATH includes the correct binaries
