## MODIFIED Requirements

### Requirement: Delete specific generations
`snix system delete-generations` SHALL remove generation directories and their GC roots for the selected generations. It SHALL refuse to delete the current generation or the boot-default generation.

#### Scenario: Delete by ID list
- **WHEN** generations 1, 2, 3, 4, 5 exist and generation 5 is current
- **AND** user runs `snix system delete-generations 1 3`
- **THEN** generations 1 and 3 are removed
- **AND** GC roots `gen-1-*` and `gen-3-*` are removed
- **AND** generations 2, 4, 5 remain

#### Scenario: Delete all but last N
- **WHEN** generations 1 through 8 exist and generation 8 is current
- **AND** user runs `snix system delete-generations +3`
- **THEN** generations 1, 2, 3, 4, 5 are deleted
- **AND** generations 6, 7, 8 are preserved

#### Scenario: Delete all old generations
- **WHEN** generations 1, 2, 3, 4 exist and generation 4 is current
- **AND** user runs `snix system delete-generations old`
- **THEN** generations 1, 2, 3 are deleted
- **AND** generation 4 is preserved

#### Scenario: Refuse to delete current generation
- **WHEN** generation 5 is current
- **AND** user runs `snix system delete-generations 5`
- **THEN** snix reports that generation 5 is current and cannot be deleted
- **AND** generation 5 is unchanged

#### Scenario: Protect boot-default generation
- **WHEN** generation 5 is current
- **AND** `/etc/redox-system/boot-default` contains `3`
- **AND** user runs `snix system delete-generations old`
- **THEN** generation 3 is preserved as boot-default
- **AND** generation 5 is preserved as current
- **AND** only the remaining non-protected generations are deleted

#### Scenario: Dry run reports plan without deleting
- **WHEN** user runs `snix system delete-generations --dry-run old`
- **THEN** the output lists which generations would be deleted
- **AND** no generation directories or GC roots are removed

### Requirement: Delete generations older than N days
`snix system delete-generations Nd` SHALL delete all non-current, non-boot-default generations with a creation timestamp older than N days.

#### Scenario: Delete generations older than 14 days
- **WHEN** generations 1 (old), 2 (fresh), 3 (current) exist
- **AND** user runs `snix system delete-generations 14d`
- **THEN** generation 1 is deleted
- **AND** generations 2 and 3 remain
