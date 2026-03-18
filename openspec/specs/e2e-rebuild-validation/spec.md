## ADDED Requirements

### Requirement: Initial system state includes environment.etc files and activation script markers
The test VM SHALL boot with environment.etc files written to disk and activation scripts executed during initial activation, proving the build system correctly bakes these into the disk image.

#### Scenario: Environment.etc files present after boot
- **WHEN** the VM boots with a profile that declares `"/environment".etc` entries
- **THEN** the declared files SHALL exist on disk with the specified content

#### Scenario: Activation script markers present after boot
- **WHEN** the VM boots with a profile that declares `"/activation".scripts` with dependency ordering
- **THEN** the marker files created by those scripts SHALL exist on disk

### Requirement: Rebuild applies configuration changes to the live system
`snix system rebuild --config <json>` SHALL evaluate the config, merge it with the current manifest, and activate the result — updating hostname, writing new etc files, running activation scripts, and creating a new generation.

#### Scenario: Hostname change via rebuild
- **WHEN** the user runs rebuild with a JSON config containing a different hostname
- **THEN** `/etc/hostname` SHALL contain the new hostname
- **AND** `snix system info` SHALL report the new hostname

#### Scenario: New etc file added via rebuild
- **WHEN** the rebuild config adds a new `files` entry (e.g., `etc/rebuild-marker`)
- **THEN** the file SHALL exist on disk with the specified content after rebuild

#### Scenario: Activation scripts execute during rebuild
- **WHEN** the rebuild config includes activation scripts
- **THEN** the scripts SHALL execute in dependency order and their side effects (marker files) SHALL be observable

#### Scenario: Generation created after rebuild
- **WHEN** rebuild succeeds
- **THEN** a new generation SHALL exist in the generations directory
- **AND** the generation count SHALL increase by one

### Requirement: No-op rebuild detects no changes
When `snix system rebuild` is run with the same configuration as the current system, it SHALL detect that no changes are needed and report a no-op result without creating a new generation.

#### Scenario: Identical rebuild is a no-op
- **WHEN** the user runs rebuild with the same config that is already active
- **THEN** snix SHALL report no changes
- **AND** the generation count SHALL remain the same

### Requirement: Rollback restores previous system state
`snix system switch --rollback` SHALL revert the system to the previous generation's state, restoring the prior hostname, etc files, and activation state.

#### Scenario: Rollback restores hostname
- **WHEN** the user runs rollback after a rebuild that changed the hostname
- **THEN** `/etc/hostname` SHALL contain the original hostname

#### Scenario: Rollback creates a new generation
- **WHEN** rollback succeeds
- **THEN** a new generation SHALL be created (rollback is itself a switch operation)
- **AND** the generation's manifest SHALL match the rolled-back-to state
