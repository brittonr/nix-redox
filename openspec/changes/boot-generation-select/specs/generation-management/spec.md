## MODIFIED Requirements

### Requirement: Switch activates a specific manifest as a new generation
`snix system switch` SHALL install a provided manifest as the current system, saving the previous state as a generation. It SHALL also update the boot default marker.

#### Scenario: Switch to a generation's manifest
- **WHEN** generation 1's manifest is passed to `snix system switch`
- **THEN** the system activates that manifest
- **AND** a new generation is created
- **AND** `/boot/default-generation` is updated to the new generation's ID

#### Scenario: Dry-run switch shows changes without applying
- **WHEN** `snix system switch --dry-run` is run with a different manifest
- **THEN** the planned changes are displayed
- **AND** no files are modified
- **AND** `/boot/default-generation` is not changed

### Requirement: Rollback restores previous generation state
`snix system rollback` SHALL revert the system to the previous generation's manifest and activate it. It SHALL also update the boot default marker.

#### Scenario: Rollback after hostname change
- **WHEN** the system was rebuilt with a hostname change (generation 2 is current)
- **AND** `snix system rollback` is run
- **THEN** `/etc/hostname` contains the original hostname from generation 1
- **AND** the current manifest reflects the pre-rebuild state
- **AND** a new generation (3) is created representing the rollback state
- **AND** `/boot/default-generation` is updated to the new generation's ID

#### Scenario: Rollback to specific generation
- **WHEN** multiple generations exist (1, 2, 3)
- **AND** `snix system rollback --generation 1` is run
- **THEN** the system reverts to generation 1's manifest
- **AND** a new generation (4) is created with description indicating rollback to 1
- **AND** `/boot/default-generation` is updated to `4`

#### Scenario: Rollback with no previous generations
- **WHEN** only one generation exists
- **AND** `snix system rollback` is run
- **THEN** the command reports an error that no previous generation exists
- **AND** the system state is unchanged
- **AND** `/boot/default-generation` is not changed
