## MODIFIED Requirements

### Requirement: List system generations
`snix system generations` SHALL list all saved generations with their ID, timestamp, and description. The current generation SHALL be marked. Output SHALL be sorted by generation number ascending.

#### Scenario: List with multiple generations
- **WHEN** three generations exist (1, 2, 3) and generation 3 is current
- **AND** user runs `snix system generations`
- **THEN** output lists all three with timestamps
- **AND** generation 3 is marked as `(current)`

#### Scenario: List with single generation
- **WHEN** only generation 1 exists
- **THEN** output shows generation 1 marked as `(current)`

### Requirement: Switch to a previous generation
`snix system switch-generation N` SHALL activate generation N by updating the `/nix/system/current` symlink, writing that generation's etc files, and restarting changed services. The switch SHALL NOT delete any other generations.

#### Scenario: Switch to older generation
- **WHEN** generations 1, 2, 3 exist and generation 3 is current
- **AND** user runs `snix system switch-generation 2`
- **THEN** `/nix/system/current` points to generation 2
- **AND** etc files reflect generation 2's manifest
- **AND** generations 1, 2, 3 all still exist

#### Scenario: Switch to nonexistent generation
- **WHEN** user runs `snix system switch-generation 99`
- **AND** generation 99 does not exist
- **THEN** snix reports an error listing available generations

#### Scenario: Switch recommends reboot when boot components differ
- **WHEN** generation 2 has different boot components than the running kernel
- **AND** user switches to generation 2
- **THEN** the switch succeeds
- **AND** a message warns that reboot is recommended

### Requirement: Rollback to previous generation
`snix system rollback` SHALL switch to generation N-1 where N is the current generation number. This is a convenience wrapper around `switch-generation`.

#### Scenario: Rollback from generation 3
- **WHEN** generation 3 is current
- **AND** user runs `snix system rollback`
- **THEN** generation 2 becomes current

#### Scenario: Rollback from generation 1
- **WHEN** generation 1 is current (no prior generation)
- **AND** user runs `snix system rollback`
- **THEN** snix reports that there is no previous generation to roll back to
