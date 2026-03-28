## MODIFIED Requirements

### Requirement: Services render to TOML unit files instead of shell script text

The `renderServiceText` function SHALL produce TOML content for a `.service` file instead of shell script lines. The module declaration API (type, command, args, environment, after, wantedBy) is unchanged.

#### Scenario: Scheme service rendering

- **GIVEN** a service with `type = "scheme"`, `args = "null"`, `command = "zerod"`
- **WHEN** `renderServiceText` is called
- **THEN** the output is valid TOML with `[unit]` and `[service]` sections
- **AND** `type = { scheme = "null" }` appears under `[service]`

#### Scenario: Environment variables in TOML

- **GIVEN** a service with `environment = { VT = "3", DISPLAY = ":0" }`
- **WHEN** rendered as TOML
- **THEN** the `[service]` section contains `envs = { DISPLAY = ":0", VT = "3" }`
- **AND** no `export` shell lines appear

### Requirement: Service files use .service extension in output path

The `renderedServices` map SHALL produce filenames with `.service` extension instead of extensionless names.

#### Scenario: Auto-numbered service filename

- **GIVEN** a service `smolnetd` assigned number 42
- **WHEN** the service is rendered
- **THEN** the output key is `42_smolnetd.service` (not `42_smolnetd`)
- **AND** the file `directory` is `usr/lib/init.d` for rootfs or `etc/init.d` for initfs

### Requirement: Initfs scripts replaced by unit files and targets

The `defaultInitScriptFiles` map SHALL produce `.service` and `.target` TOML files instead of shell scripts for the initfs boot sequence.

#### Scenario: Old 00_runtime shell script replaced

- **GIVEN** the old `00_runtime` script with `export PATH`, `rtcd`, `scheme null nulld`
- **WHEN** the new initfs files are generated
- **THEN** `00_runtime.target` exists with `requires_weak` listing all runtime services
- **AND** separate `.service` files exist for each daemon (nulld, zerod, randd, rtcd)
- **AND** no `export PATH` or `export LD_LIBRARY_PATH` appears (handled by init's SwitchRoot)

#### Scenario: Old 90_exit_initfs replaced

- **GIVEN** the old `90_exit_initfs` script with `run.d`, `export PATH`, env setup
- **WHEN** the new initfs files are generated
- **THEN** `90_initfs.target` exists as a dependency grouping target
- **AND** no `run.d` or `switchroot` commands appear in any file

### Requirement: Post-switchroot environment setup preserved

Environment variables set after rootfs mount (TERM, HOME, USER, XDG_CONFIG_HOME, CARGO_HOME, LD_LIBRARY_PATH for self-hosting) SHALL still be configured, using a legacy extensionless init script in `usr/lib/init.d/`.

#### Scenario: Self-hosting env vars available after boot

- **GIVEN** a profile with self-hosting enabled
- **WHEN** the rootfs is assembled
- **THEN** a legacy init script in `usr/lib/init.d/` sets LD_LIBRARY_PATH, CARGO_HOME, CARGO_BUILD_JOBS
- **AND** a legacy init script sets TERM, HOME, USER, XDG_CONFIG_HOME, PATH
