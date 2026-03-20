## MODIFIED Requirements

### Requirement: Modules declare services through structured options
Each module (networking, graphics, snix, etc.) SHALL declare its services using a `services` option in its own module namespace with a `defaultFunc` that computes service entries from the module's options. The build system SHALL collect services from all module inputs and merge them into a single service set.

#### Scenario: Networking module declares smolnetd
- **WHEN** `networking.enable = true`
- **THEN** `networking.services` contains a `smolnetd` entry with `type = "daemon"` and `command = "/bin/smolnetd"`

#### Scenario: Networking disabled omits smolnetd
- **WHEN** `networking.enable = false`
- **THEN** `networking.services` is empty

#### Scenario: Graphics module declares orbital
- **WHEN** `graphics.enable = true`
- **THEN** `graphics.services` contains an `orbital` entry with `type = "nowait"` and `environment` containing `VT = "3"`

#### Scenario: Multiple modules contribute services
- **WHEN** both networking and graphics are enabled
- **THEN** the merged service set collected by `/build` contains entries from both modules
- **AND** no naming conflicts exist
