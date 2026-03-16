## ADDED Requirements

### Requirement: Delete specific generations
`snix system delete-generations` SHALL remove generation directories and their GC roots for the specified generations. It SHALL refuse to delete the current generation or the boot-default generation.

#### Scenario: Delete by ID list
- **WHEN** generations 1, 2, 3, 4, 5 exist and generation 5 is current
- **AND** `snix system delete-generations 1 3` is run
- **THEN** `/etc/redox-system/generations/1/` and `/etc/redox-system/generations/3/` are removed
- **AND** GC roots `gen-1-*` and `gen-3-*` are removed from `/nix/var/snix/gcroots/`
- **AND** generations 2, 4, 5 are unchanged

#### Scenario: Delete all but last N
- **WHEN** generations 1 through 8 exist and generation 8 is current
- **AND** `snix system delete-generations +3` is run
- **THEN** generations 1, 2, 3, 4, 5 are deleted (directories and GC roots)
- **AND** generations 6, 7, 8 are preserved

#### Scenario: Delete older than N days
- **WHEN** generations 1 (30 days old), 2 (10 days old), 3 (1 day old) exist
- **AND** `snix system delete-generations 14d` is run
- **THEN** generation 1 is deleted
- **AND** generations 2, 3 are preserved

#### Scenario: Delete all old generations
- **WHEN** generations 1, 2, 3, 4 exist and generation 4 is current
- **AND** `snix system delete-generations old` is run
- **THEN** generations 1, 2, 3 are deleted
- **AND** generation 4 is preserved

#### Scenario: Refuse to delete current generation
- **WHEN** generation 5 is the current generation
- **AND** `snix system delete-generations 5` is run
- **THEN** the command reports that generation 5 is current and cannot be deleted
- **AND** generation 5 is unchanged

#### Scenario: Protect boot-default generation
- **WHEN** `/etc/redox-system/boot-default` contains `3`
- **AND** generation 5 is the current running generation
- **AND** `snix system delete-generations old` is run
- **THEN** generations other than 3 and 5 are deleted
- **AND** generation 3 is preserved (boot-default protected)
- **AND** generation 5 is preserved (current protected)

#### Scenario: Dry run shows plan without deleting
- **WHEN** `snix system delete-generations --dry-run old` is run
- **THEN** the output lists which generations would be deleted
- **AND** no generation directories or GC roots are removed

#### Scenario: No generations to delete
- **WHEN** only the current generation exists
- **AND** `snix system delete-generations old` is run
- **THEN** the command reports nothing to delete
- **AND** exits successfully

### Requirement: System GC combines generation pruning and store sweep
`snix system gc` SHALL delete old generations and then run store garbage collection in that order.

#### Scenario: System GC with keep flag
- **WHEN** generations 1 through 6 exist (generation 6 is current)
- **AND** `snix system gc --keep 3` is run
- **THEN** generations 1, 2, 3 are deleted (directories and GC roots)
- **AND** store paths only referenced by deleted generations are removed from `/nix/store`
- **AND** store paths referenced by generations 4, 5, 6 are preserved

#### Scenario: System GC dry run
- **WHEN** `snix system gc --keep 2 --dry-run` is run
- **THEN** the output shows which generations would be pruned
- **AND** the output shows which store paths would be freed and bytes reclaimable
- **AND** nothing is modified

#### Scenario: System GC default (delete all old)
- **WHEN** `snix system gc` is run without flags
- **THEN** all generations except the current are deleted
- **AND** store GC runs and reclaims unreferenced paths

### Requirement: Per-generation GC roots
Each generation's store paths SHALL be individually rooted in `/nix/var/snix/gcroots/` using the naming convention `gen-{N}-{pkg_name}`.

#### Scenario: Switch creates roots for new generation
- **WHEN** `snix system switch` creates generation 3
- **THEN** GC roots `gen-3-base`, `gen-3-ion`, `gen-3-kernel` (etc.) exist in `/nix/var/snix/gcroots/`
- **AND** each root symlinks to the corresponding package's store path

#### Scenario: Old generation roots survive switch
- **WHEN** generation 2 was created with roots `gen-2-base`, `gen-2-ion`
- **AND** `snix system switch` creates generation 3
- **THEN** roots `gen-2-base`, `gen-2-ion` still exist in `/nix/var/snix/gcroots/`
- **AND** roots `gen-3-base`, `gen-3-ion`, `gen-3-ripgrep` also exist

#### Scenario: Store GC preserves all rooted generations
- **WHEN** generations 1, 2, 3 exist with their GC roots
- **AND** `snix store gc` is run
- **THEN** all store paths referenced by generations 1, 2, 3 are preserved
- **AND** only paths not referenced by any generation are deleted

### Requirement: Migration from old root naming
On the first switch/rollback after upgrade, the system SHALL migrate from `system-{pkg}` roots to `gen-{N}-{pkg}` roots for all existing generations.

#### Scenario: First switch migrates roots
- **WHEN** GC roots `system-base`, `system-ion` exist (old naming)
- **AND** generations 1, 2, 3 exist in `/etc/redox-system/generations/`
- **AND** `snix system switch` is run
- **THEN** `system-*` roots are removed
- **AND** `gen-1-*`, `gen-2-*`, `gen-3-*` roots are created for each generation's packages
- **AND** `gen-4-*` roots are created for the new generation

#### Scenario: No old roots to migrate
- **WHEN** no `system-*` roots exist
- **AND** `snix system switch` is run
- **THEN** migration is skipped (no error)
- **AND** `gen-{N}-*` roots are created normally
