## ADDED Requirements

### Requirement: Modules declare services through structured options
Each module (networking, graphics, snix, etc.) SHALL declare its services using `"/services".services.<name>` entries in its `impl` output. The build system SHALL merge all module service declarations into a single service set.

#### Scenario: Networking module declares smolnetd
- **WHEN** `networking.enable = true`
- **THEN** the merged service set contains a `smolnetd` entry with `type = "daemon"` and `command = "/bin/smolnetd"`

#### Scenario: Networking disabled omits smolnetd
- **WHEN** `networking.enable = false`
- **THEN** the merged service set does not contain a `smolnetd` entry

#### Scenario: Graphics module declares orbital
- **WHEN** `graphics.enable = true`
- **THEN** the merged service set contains an `orbital` entry with `type = "nowait"` and `environment` containing `VT = "3"`

#### Scenario: Multiple modules contribute services
- **WHEN** both networking and graphics are enabled
- **THEN** the merged service set contains entries from both modules
- **AND** no naming conflicts exist

### Requirement: Services declare dependencies with after field
Each service MAY declare an `after` field containing a list of service names that MUST start before it. The build system SHALL topologically sort services and reject cycles at build time.

#### Scenario: Getty depends on ptyd
- **WHEN** the `getty` service declares `after = [ "ptyd" ]`
- **THEN** the generated init script for `getty` has a higher numeric prefix than `ptyd`

#### Scenario: Dependency cycle is rejected
- **WHEN** service `a` declares `after = [ "b" ]` and service `b` declares `after = [ "a" ]`
- **THEN** the build fails with an error message identifying the cycle

#### Scenario: No dependencies produces alphabetical ordering
- **WHEN** services `smolnetd` and `dhcpd` both have empty `after` lists and the same `wantedBy` target
- **THEN** the generated init scripts are ordered alphabetically (`dhcpd` before `smolnetd`)

### Requirement: Services have per-service environment variables
Each service MAY declare an `environment` attrset. The build system SHALL render each key-value pair as an `export KEY VALUE` line before the service command in the generated init script.

#### Scenario: Orbital has VT environment variable
- **WHEN** the `orbital` service declares `environment = { VT = "3"; }`
- **THEN** the generated init script contains `export VT 3` before the orbital command

#### Scenario: Multiple environment variables rendered in order
- **WHEN** a service declares `environment = { A = "1"; B = "2"; }`
- **THEN** the generated init script contains `export A 1` and `export B 2` before the service command, sorted alphabetically

### Requirement: Services are rendered to numbered init scripts
The build system SHALL render each enabled service declaration into a numbered init script file. Initfs services go to `etc/init.d/`, rootfs services go to `usr/lib/init.d/`.

#### Scenario: Rootfs service generates usr/lib/init.d script
- **WHEN** a service `getty` has `wantedBy = "rootfs"` and is assigned number 30
- **THEN** a file `usr/lib/init.d/30_getty` is generated in the rootTree

#### Scenario: Initfs service generates etc/init.d script
- **WHEN** a service `logd` has `wantedBy = "initfs"` and is assigned number 10
- **THEN** a file `etc/init.d/10_logd` is generated in the rootTree

#### Scenario: Disabled service produces no init script
- **WHEN** a service has `enable = false`
- **THEN** no init script is generated for that service

### Requirement: Raw initScripts coexist with structured services
The `services.initScripts` option SHALL continue to work alongside structured service declarations. Raw scripts use explicitly numbered names and are not subject to auto-numbering.

#### Scenario: Raw script and structured service both rendered
- **WHEN** `initScripts` contains `"00_runtime"` and `services` contains `smolnetd`
- **THEN** both `etc/init.d/00_runtime` and the auto-numbered smolnetd script appear in the rootTree

#### Scenario: Reserved number ranges prevent collisions
- **WHEN** auto-numbered services are assigned numbers
- **THEN** auto-numbering uses range 10-79 and does not overlap with raw script numbers in 00-09 or 80-99

### Requirement: Service type determines startup command format
The service `type` field SHALL control how the command is rendered in the init script: `daemon` uses `notify`, `nowait` uses `nowait`, `scheme` uses `scheme <args> <command>`, `oneshot` uses bare command.

#### Scenario: Daemon service uses notify
- **WHEN** a service has `type = "daemon"` and `command = "/bin/ptyd"`
- **THEN** the init script line is `notify /bin/ptyd`

#### Scenario: Scheme service uses scheme prefix
- **WHEN** a service has `type = "scheme"`, `command = "nulld"`, and `args = "null"`
- **THEN** the init script line is `scheme null nulld`

#### Scenario: Oneshot service uses bare command
- **WHEN** a service has `type = "oneshot"` and `command = "rtcd"`
- **THEN** the init script line is `rtcd`

### Requirement: Build check validates service dependency graph
The build system SHALL include a check that verifies the service dependency graph is acyclic and all referenced dependencies exist.

#### Scenario: Valid dependency graph passes check
- **WHEN** all service `after` references point to existing services
- **AND** no cycles exist
- **THEN** the build check passes

#### Scenario: Missing dependency fails check
- **WHEN** a service declares `after = [ "nonexistent" ]`
- **THEN** the build check fails with an error identifying the unknown dependency

### Requirement: Manifest tracks full service declarations
The system manifest SHALL include the full set of declared services with their type, command, wantedBy, and environment fields. This data is used by the activation plan to produce meaningful service diffs.

#### Scenario: Manifest includes service metadata
- **WHEN** the system has `smolnetd` declared as `type = "daemon"`, `wantedBy = "rootfs"`
- **THEN** the manifest JSON at `/etc/redox-system/manifest.json` contains a `services.declared` object with `smolnetd` and its full metadata

#### Scenario: Manifest reflects disabled services as absent
- **WHEN** a service has `enable = false`
- **THEN** the `services.declared` object does not contain that service
