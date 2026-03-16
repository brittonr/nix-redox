## ADDED Requirements

### Requirement: List system generations
`snix system generations` SHALL list all saved generations with their ID, timestamp, and description.

#### Scenario: List after first rebuild
- **WHEN** the system has been rebuilt once (creating generations 1 and 2)
- **AND** `snix system generations` is run
- **THEN** the output lists at least two generations with IDs, timestamps, and descriptions
- **AND** the current generation is indicated

#### Scenario: List with no generations directory
- **WHEN** no generations exist in `/etc/redox-system/generations/`
- **AND** `snix system generations` is run
- **THEN** the command exits without error and reports no generations found

### Requirement: Rollback restores previous generation state
`snix system rollback` SHALL revert the system to the previous generation's manifest and activate it.

#### Scenario: Rollback after hostname change
- **WHEN** the system was rebuilt with a hostname change (generation 2 is current)
- **AND** `snix system rollback` is run
- **THEN** `/etc/hostname` contains the original hostname from generation 1
- **AND** the current manifest reflects the pre-rebuild state
- **AND** a new generation (3) is created representing the rollback state

#### Scenario: Rollback to specific generation
- **WHEN** multiple generations exist (1, 2, 3)
- **AND** `snix system rollback --generation 1` is run
- **THEN** the system reverts to generation 1's manifest
- **AND** a new generation (4) is created with description indicating rollback to 1

#### Scenario: Rollback with no previous generations
- **WHEN** only one generation exists
- **AND** `snix system rollback` is run
- **THEN** the command reports an error that no previous generation exists
- **AND** the system state is unchanged

### Requirement: Switch activates a specific manifest as a new generation
`snix system switch` SHALL install a provided manifest as the current system, saving the previous state as a generation.

#### Scenario: Switch to a generation's manifest
- **WHEN** generation 1's manifest is passed to `snix system switch`
- **THEN** the system activates that manifest
- **AND** a new generation is created

#### Scenario: Dry-run switch shows changes without applying
- **WHEN** `snix system switch --dry-run` is run with a different manifest
- **THEN** the planned changes are displayed
- **AND** no files are modified

### Requirement: Generations persist across the test lifecycle
Generation directories SHALL survive the full test sequence (rebuild → list → rollback → list) without corruption.

#### Scenario: Full lifecycle integrity
- **WHEN** the system goes through rebuild, generation listing, rollback, and second listing
- **THEN** all generation directories contain valid `manifest.json` files
- **AND** generation IDs are monotonically increasing
- **AND** the final manifest matches the expected rollback state
