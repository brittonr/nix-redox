## ADDED Requirements

### Requirement: Service rendering produces TOML unit files

The build system SHALL render each declared service as a TOML file with `[unit]` and `[service]` sections conforming to the upstream init binary's `serde(deny_unknown_fields)` schema.

#### Scenario: Scheme daemon service

- **GIVEN** a service with `type = "scheme"`, `command = "nulld"`, `args = "null"`
- **WHEN** the service is rendered
- **THEN** a file `XX_nulld.service` is produced containing:
  ```toml
  [unit]
  description = "..."

  [service]
  cmd = "nulld"
  args = ["null"]
  type = { scheme = "null" }
  ```

#### Scenario: Notify daemon service

- **GIVEN** a service with `type = "daemon"`, `command = "vesad"`
- **WHEN** the service is rendered
- **THEN** the TOML `type` field is `"notify"`

#### Scenario: Oneshot service

- **GIVEN** a service with `type = "oneshot"`, `command = "rtcd"`
- **WHEN** the service is rendered
- **THEN** the TOML `type` field is `"oneshot"`

#### Scenario: Nowait service maps to oneshot_async

- **GIVEN** a service with `type = "nowait"`, `command = "cmd"`
- **WHEN** the service is rendered
- **THEN** the TOML `type` field is `"oneshot_async"`

#### Scenario: Service with environment variables

- **GIVEN** a service with `environment = { VT = "3" }`
- **WHEN** the service is rendered
- **THEN** the TOML contains `envs = { VT = "3" }` under `[service]`

### Requirement: Target files group dependencies

The build system SHALL generate `.target` files that declare `requires_weak` lists to group related services.

#### Scenario: Runtime target groups core daemons

- **GIVEN** initfs services nulld, zerod, randd, rtcd are declared with `wantedBy = "initfs"`
- **WHEN** the initfs unit files are generated
- **THEN** a `00_runtime.target` file exists with `requires_weak` listing all four service filenames
- **AND** the target has `default_dependencies = false`

#### Scenario: Initfs target requires rootfs mount

- **WHEN** the initfs unit files are generated
- **THEN** a `90_initfs.target` file exists with `requires_weak` including the rootfs mount service

### Requirement: Dependencies emit requires_weak references

Each service that declares `after = ["dep"]` SHALL have a `requires_weak` entry in its `[unit]` section referencing the dependency's unit filename.

#### Scenario: Service with after dependency

- **GIVEN** service `smolnetd` declares `after = ["pcid-spawner"]`
- **AND** `pcid-spawner` renders as `40_pcid-spawner.service`
- **WHEN** `smolnetd` is rendered
- **THEN** its `[unit]` section contains `requires_weak = ["40_pcid-spawner.service"]`

### Requirement: Unit files written with correct extensions

Initfs unit files SHALL be written to `etc/init.d/` with `.service` or `.target` extensions. Rootfs unit files SHALL be written to `usr/lib/init.d/` with the same extensions.

#### Scenario: Initfs directory contains unit files

- **WHEN** the initfs is assembled
- **THEN** `etc/init.d/` contains files named `*.service` and `*.target`
- **AND** no extensionless shell scripts exist for services that have been converted

#### Scenario: Rootfs directory contains unit files

- **WHEN** the rootfs tree is assembled
- **THEN** `usr/lib/init.d/` contains `.service` files for rootfs services

### Requirement: Logd excluded from generated services

The `logd` service SHALL NOT be generated as a unit file because the init binary starts it explicitly between the two `SwitchRoot` calls.

#### Scenario: Logd not in initfs init.d

- **WHEN** initfs unit files are generated
- **THEN** no `*logd*` service file exists in `etc/init.d/`

### Requirement: default_dependencies controls runtime target gating

Services with `default_dependencies = false` SHALL include that field in their `[unit]` section. Services without it (or with `true`) SHALL omit the field, relying on the upstream default.

#### Scenario: Core runtime daemon skips runtime target wait

- **GIVEN** nulld is part of `00_runtime.target`
- **WHEN** nulld's service file is generated
- **THEN** its `[unit]` section contains `default_dependencies = false`

#### Scenario: Normal service uses default

- **GIVEN** smolnetd is a rootfs service
- **WHEN** its service file is generated
- **THEN** `default_dependencies` is NOT present in the `[unit]` section
