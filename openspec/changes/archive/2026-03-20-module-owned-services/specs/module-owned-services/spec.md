## ADDED Requirements

### Requirement: Shared serviceType definition
A shared service type definition SHALL exist at `nix/redox-system/lib/service-type.nix` that takes `{ t }` (korora types) and returns a struct type matching the existing `serviceType` in `services.nix`.

#### Scenario: Type definition importable by any module
- **WHEN** a module imports `service-type.nix` with its local `t = adios.types`
- **THEN** the returned type is usable in `t.attrsOf serviceType` option declarations

#### Scenario: Type matches existing service fields
- **WHEN** the shared type is used
- **THEN** it defines `description`, `command`, `type`, `args`, `wantedBy`, `enable`, `after`, `environment`, and `priority` with the same types as the current `serviceType` in `services.nix`

### Requirement: Networking module declares its own services
The `/networking` module SHALL declare a `services` option of type `t.attrsOf serviceType` with a `defaultFunc` that computes service entries based on networking options.

#### Scenario: Networking enabled with DHCP mode
- **WHEN** `networking.enable = true` and `networking.mode = "dhcp"`
- **THEN** `networking.services` contains `smolnetd` (daemon) and `dhcpd` (nowait)

#### Scenario: Networking enabled with static mode
- **WHEN** `networking.enable = true` and `networking.mode = "static"`
- **THEN** `networking.services` contains `smolnetd` (daemon) and `netcfg-static` (oneshot)

#### Scenario: Networking enabled with auto mode
- **WHEN** `networking.enable = true` and `networking.mode = "auto"`
- **THEN** `networking.services` contains `smolnetd`, `dhcpd`, and `netcfg-auto`

#### Scenario: Networking disabled
- **WHEN** `networking.enable = false`
- **THEN** `networking.services` is empty

#### Scenario: Remote shell enabled
- **WHEN** `networking.enable = true` and `networking.remoteShellEnable = true`
- **THEN** `networking.services` contains `remote-shell` with after `[ "smolnetd" ]`

### Requirement: Graphics module declares its own services
The `/graphics` module SHALL declare a `services` option with a `defaultFunc` that computes service entries. The module SHALL have inputs for `/hardware` and `/pkgs`.

#### Scenario: Graphics enabled with audio
- **WHEN** `graphics.enable = true` and `hardware.audioEnable = true`
- **THEN** `graphics.services` contains `orbital` (nowait, VT environment) and `audiod` (daemon)

#### Scenario: Graphics enabled without audio
- **WHEN** `graphics.enable = true` and `hardware.audioEnable = false`
- **THEN** `graphics.services` contains `orbital` but not `audiod`

#### Scenario: Graphics disabled
- **WHEN** `graphics.enable = false`
- **THEN** `graphics.services` is empty

#### Scenario: Orbital login command uses orbutils when available
- **WHEN** `graphics.enable = true` and `pkgs.orbutils` exists
- **THEN** the `orbital` service args include `orblogin orbterm`

### Requirement: Snix module declares its own services
The `/snix` module SHALL declare a `services` option with a `defaultFunc` that computes service entries based on stored and profiled enable flags.

#### Scenario: Stored enabled
- **WHEN** `snix.stored.enable = true`
- **THEN** `snix.services` contains `stored` (nowait) with cache path and store dir args

#### Scenario: Profiled enabled
- **WHEN** `snix.profiled.enable = true`
- **THEN** `snix.services` contains `profiled` (nowait) with profiles dir and store dir args

#### Scenario: Both disabled
- **WHEN** `snix.stored.enable = false` and `snix.profiled.enable = false`
- **THEN** `snix.services` is empty

### Requirement: Iroh module declares its own services
The `/iroh` module SHALL declare a `services` option with a `defaultFunc` that computes service entries based on iroh enable flag.

#### Scenario: Iroh enabled
- **WHEN** `iroh.enable = true`
- **THEN** `iroh.services` contains `irohd` (nowait) with key-path and peers-path args and after `[ "smolnetd" ]`

#### Scenario: Iroh disabled
- **WHEN** `iroh.enable = false`
- **THEN** `iroh.services` is empty

### Requirement: Services module owns core and typed services
The `/services` module SHALL have a `/pkgs` input and its `services` option `defaultFunc` SHALL generate core services (ipcd, ptyd), typed service module entries (ssh, httpd, getty, exampled), and sudod.

#### Scenario: Core services always present
- **WHEN** any configuration is evaluated
- **THEN** `services.services` contains `ipcd` (daemon, priority 10) and `ptyd` (daemon, priority 11, after ipcd)

#### Scenario: Getty auto resolves to enabled
- **WHEN** `services.getty.enable = "auto"` and userutils is in system packages
- **THEN** `services.services` contains `getty` (nowait, after ptyd)

#### Scenario: Getty auto resolves to disabled
- **WHEN** `services.getty.enable = "auto"` and userutils is not in system packages
- **THEN** `services.services` does not contain `getty`

#### Scenario: SSH enabled generates sshd
- **WHEN** `services.ssh.enable = true`
- **THEN** `services.services` contains `sshd` (nowait, after ptyd and smolnetd)

#### Scenario: Sudod enabled when userutils installed
- **WHEN** userutils is in system packages
- **THEN** `services.services` contains `sudod` (daemon, after ptyd)

#### Scenario: Profile-declared services merged
- **WHEN** a profile sets `/services.services.custom = { ... }`
- **THEN** the custom service appears in the merged output alongside generated services

### Requirement: Build module collects services from all inputs
The build module's `init-scripts.nix` SHALL collect services from `inputs.services.services`, `inputs.networking.services`, `inputs.graphics.services`, `inputs.snix.services`, and `inputs.iroh.services`, merging them with right-side-wins precedence.

#### Scenario: All module services merged
- **WHEN** networking, graphics, snix, and iroh are all enabled
- **THEN** the merged service set contains entries from all modules

#### Scenario: Module services do not duplicate build-module logic
- **WHEN** `init-scripts.nix` is examined
- **THEN** it contains no per-module conditional service blocks (no `lib.optionalAttrs cfg.networkingEnabled`, etc.)

#### Scenario: Existing test suite passes
- **WHEN** `nix run .#test-quick` and `nix run .#test-host` are run
- **THEN** all eval, artifact, type, and lib tests pass without modification
