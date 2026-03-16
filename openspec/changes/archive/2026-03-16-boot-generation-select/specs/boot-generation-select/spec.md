## ADDED Requirements

### Requirement: Boot-time generation activation
The init system SHALL activate the default generation's manifest after root mount and before userspace entry, restoring the generation's package profile and config files.

#### Scenario: Boot with default-generation marker set
- **WHEN** `/etc/redox-system/boot-default` contains `3`
- **AND** generation 3 exists in `/etc/redox-system/generations/3/manifest.json`
- **AND** the system boots
- **THEN** `/nix/system/profile/bin/` reflects generation 3's package set
- **AND** `/etc/hostname` reflects generation 3's hostname
- **AND** the system reaches userspace with generation 3 active

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

#### Scenario: Boot with corrupt generation manifest
- **WHEN** `/etc/redox-system/boot-default` references a generation with invalid JSON in its manifest
- **AND** the system boots
- **THEN** a warning is logged to serial output
- **AND** the system boots with the current on-disk manifest

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

### Requirement: activate-boot subcommand
`snix system activate-boot` SHALL activate a generation's manifest without creating a new generation entry.

#### Scenario: Activate a stored generation at boot
- **WHEN** `snix system activate-boot --generation 3` is run
- **AND** generation 3 exists
- **THEN** `/nix/system/profile/bin/` is rebuilt with generation 3's packages
- **AND** `/etc/hostname` is updated to generation 3's hostname
- **AND** `/etc/redox-system/manifest.json` is updated to generation 3's manifest
- **AND** no new generation directory is created in `/etc/redox-system/generations/`

#### Scenario: Activate nonexistent generation
- **WHEN** `snix system activate-boot --generation 99` is run
- **AND** generation 99 does not exist
- **THEN** the command exits with a non-zero status
- **AND** no files are modified

### Requirement: snix system boot sets next-boot generation
`snix system boot` SHALL write the default generation marker without changing the live system.

#### Scenario: Set next-boot generation
- **WHEN** `snix system boot 3` is run
- **THEN** `/etc/redox-system/boot-default` contains `3`
- **AND** the current running system is unchanged (manifest, profile, hostname all unchanged)

#### Scenario: Show current boot default
- **WHEN** `snix system boot` is run without arguments
- **AND** `/etc/redox-system/boot-default` contains `5`
- **THEN** the output shows that generation 5 is the boot default

#### Scenario: Show no boot default
- **WHEN** `snix system boot` is run without arguments
- **AND** `/etc/redox-system/boot-default` does not exist
- **THEN** the output shows that no boot default is set (system boots with current manifest)
