## ADDED Requirements

### Requirement: stateVersion option
The `/system` module SHALL define a `stateVersion` option of type integer with a default of 1. This value MUST be persisted in the system manifest and available at runtime.

#### Scenario: Default stateVersion
- **WHEN** a system is built without setting stateVersion
- **THEN** `stateVersion` is 1

#### Scenario: Explicit stateVersion
- **WHEN** a profile sets `"/system".stateVersion = 2`
- **THEN** `stateVersion` is 2 in the manifest

### Requirement: stateVersion guards default changes
Build-time logic SHALL use `stateVersion` to guard backward-incompatible default changes. When a default value changes between versions, the old default MUST be preserved for systems with a stateVersion below the version that introduced the change.

#### Scenario: Old default preserved
- **WHEN** a default changes in version 2 and a system has `stateVersion = 1`
- **THEN** the system uses the old default value

#### Scenario: New default applied
- **WHEN** a default changes in version 2 and a system has `stateVersion = 2`
- **THEN** the system uses the new default value
