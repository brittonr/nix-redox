## MODIFIED Requirements

### Requirement: End-to-end rebuild cycle tested in VM
The self-hosting test suite SHALL include a rebuild cycle test that modifies configuration.nix, runs `snix system rebuild`, and verifies the changes took effect. This goes beyond the existing initial-state tests to prove the full rebuild→activate→verify loop works on a live guest.

#### Scenario: Rebuild cycle changes hostname
- **WHEN** the test modifies `/etc/redox-system/configuration.nix` to set `hostname = "rebuilt-host"`
- **AND** runs `snix system rebuild`
- **THEN** `/etc/hostname` contains `rebuilt-host`
- **AND** `snix system info` reports `rebuilt-host`
- **AND** the test emits `FUNC_TEST:rebuild-hostname:PASS`

#### Scenario: Rebuild cycle creates a new generation
- **WHEN** the test runs `snix system rebuild` after a config change
- **THEN** `snix system generations` shows at least 2 generations
- **AND** the newest generation is marked current
- **AND** the test emits `FUNC_TEST:rebuild-generation:PASS`

#### Scenario: Rebuild cycle adds an etc file
- **WHEN** the test modifies configuration.nix to add an etc file entry
- **AND** runs `snix system rebuild`
- **THEN** the new file exists on disk with the specified content
- **AND** the test emits `FUNC_TEST:rebuild-etc-file:PASS`
