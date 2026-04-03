## MODIFIED Requirements

### Requirement: Delete specific generations
`snix system delete-generations` SHALL remove generation directories and their metadata for the specified generations. It SHALL refuse to delete the current generation or the boot-default generation.

#### Scenario: Delete old generation
- **WHEN** generations 1, 2, 3 exist and generation 3 is current
- **AND** user runs `snix system delete-generations 1`
- **THEN** `/nix/system/generations/1/` is removed
- **AND** generations 2 and 3 remain

#### Scenario: Refuse to delete current generation
- **WHEN** generation 3 is current
- **AND** user runs `snix system delete-generations 3`
- **THEN** snix reports an error: cannot delete the current generation
- **AND** generation 3 is not deleted

#### Scenario: Delete multiple generations
- **WHEN** generations 1, 2, 3, 4, 5 exist and generation 5 is current
- **AND** user runs `snix system delete-generations 1 2 3`
- **THEN** generations 1, 2, 3 are removed
- **AND** generations 4 and 5 remain

### Requirement: Delete generations older than a duration
`snix system delete-generations --older-than 30d` SHALL delete all non-current generations with a creation timestamp older than the specified duration.

#### Scenario: Delete generations older than 30 days
- **WHEN** generations 1 (45 days old), 2 (20 days old), 3 (current, 5 days old) exist
- **AND** user runs `snix system delete-generations --older-than 30d`
- **THEN** generation 1 is deleted
- **AND** generations 2 and 3 remain
