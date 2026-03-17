## ADDED Requirements

### Requirement: Declarative activation scripts
The system SHALL provide an `/activation` module with a `scripts` option that accepts an attrset of named activation script entries. Each entry SHALL have `text` (script content) and optional `deps` (list of script names to run before this one).

#### Scenario: Profile declares an activation script
- **WHEN** a profile sets `"/activation".scripts.createDirs = { text = "mkdir -p /var/cache/myapp"; deps = []; }`
- **THEN** the root tree SHALL contain `/etc/redox-system/activation.d/createDirs` with the script content and mode 0755

#### Scenario: Default empty scripts
- **WHEN** no profile sets any activation scripts
- **THEN** no `/etc/redox-system/activation.d/` directory SHALL be created and activation SHALL skip the script execution phase

### Requirement: Activation scripts execute during system switch
When `snix system switch` or `snix system activate-boot` runs, activation scripts from the target generation's manifest SHALL be executed.

#### Scenario: Switch triggers activation scripts
- **WHEN** `snix system switch` activates a generation that has activation scripts `["setupDirs", "writeMotd"]`
- **THEN** both scripts SHALL be executed during the activation phase

#### Scenario: Activate-boot triggers activation scripts
- **WHEN** `snix system activate-boot` activates a generation with activation scripts
- **THEN** the activation scripts SHALL be executed as part of boot activation

### Requirement: Dependency-ordered execution
Activation scripts SHALL be executed in topological order based on their `deps` declarations. A script with `deps = ["foo"]` SHALL run after the script named "foo".

#### Scenario: Script with dependency runs after its dependency
- **WHEN** script "writeConfig" has `deps = ["createDirs"]` AND script "createDirs" has `deps = []`
- **THEN** "createDirs" SHALL execute before "writeConfig"

#### Scenario: Multiple dependencies
- **WHEN** script "final" has `deps = ["a", "b"]` AND "a" and "b" have no deps
- **THEN** both "a" and "b" SHALL execute before "final"

### Requirement: Cycle detection
The activation system SHALL detect dependency cycles and refuse to execute scripts when a cycle exists, reporting the cycle to the user.

#### Scenario: Two-node cycle detected
- **WHEN** script "a" has `deps = ["b"]` AND script "b" has `deps = ["a"]`
- **THEN** activation SHALL report an error naming the cycle and SHALL NOT execute any activation scripts

### Requirement: Script failure is non-fatal
A failing activation script (non-zero exit code) SHALL be logged as a warning but SHALL NOT abort the activation. Other scripts SHALL continue executing.

#### Scenario: Failed script does not block others
- **WHEN** script "setup" fails with exit code 1 AND script "cleanup" has no deps on "setup"
- **THEN** "cleanup" SHALL still execute AND the activation result SHALL include a warning about "setup" failing

### Requirement: Activation scripts tracked in manifest
The manifest SHALL include an `activationScripts` field listing script names and their deps. This enables `snix system info` to display configured activation scripts.

#### Scenario: Manifest includes activation script metadata
- **WHEN** a system is built with activation scripts "createDirs" (deps: []) and "writeConfig" (deps: ["createDirs"])
- **THEN** the manifest JSON SHALL contain an `activationScripts` array with entries `{ "name": "createDirs", "deps": [] }` and `{ "name": "writeConfig", "deps": ["createDirs"] }`

### Requirement: Activation scripts run non-interactively
Activation scripts SHALL run without access to stdin. They execute as part of an automated switch process.

#### Scenario: Script stdout and stderr captured
- **WHEN** an activation script writes to stdout and stderr
- **THEN** the output SHALL be displayed during the switch and included in activation warnings if the script fails
