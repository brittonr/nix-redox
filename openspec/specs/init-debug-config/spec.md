# init-debug-config

Nix module options to control init's debug logging and command skipping,
with env var injection through a bootstrap patch and initfs env file.

### Requirement: Init debug logging option
The system SHALL provide a `boot.initDebug` Nix option (boolean, default `false`) that enables verbose debug logging in the init process during boot.

When enabled, the initfs SHALL contain an env file that causes `INIT_LOG_LEVEL=DEBUG` to be set in init's process environment via bootstrap.

#### Scenario: Debug mode disabled (default)
- **WHEN** `boot.initDebug` is not set or is `false`
- **THEN** no `etc/init.env` file is present in the initfs, and init uses its default log level (`INFO`)

#### Scenario: Debug mode enabled
- **WHEN** `boot.initDebug` is set to `true`
- **THEN** the initfs contains `etc/init.env` with `INIT_LOG_LEVEL=DEBUG`, bootstrap reads it and passes the var to init, and init sets `log_debug = true`

#### Scenario: Debug output visible on serial
- **WHEN** `boot.initDebug` is `true` and the VM is booted with serial console capture
- **THEN** serial output SHALL contain init debug lines: `init: running:` for legacy scripts, `Starting <description> (<cmd>)` for services, and `Reached target <description>` for targets

### Requirement: Init skip commands option
The system SHALL provide a `boot.initSkip` Nix option (list of strings, default `[]`) that causes init to skip named commands during boot.

Each string in the list maps to a comma-separated entry in the `INIT_SKIP` environment variable. Init matches each entry against the `cmd` field of services and skips matches with a log message.

#### Scenario: No commands skipped (default)
- **WHEN** `boot.initSkip` is not set or is empty
- **THEN** no `INIT_SKIP` entry is present in `etc/init.env` (or the file does not exist), and init processes all services normally

#### Scenario: Single command skipped
- **WHEN** `boot.initSkip` is set to `["hwd"]`
- **THEN** `etc/init.env` contains `INIT_SKIP=hwd`, and init skips any service whose `cmd` is `"hwd"` with a skip message

#### Scenario: Multiple commands skipped
- **WHEN** `boot.initSkip` is set to `["hwd", "pcid-spawner"]`
- **THEN** `etc/init.env` contains `INIT_SKIP=hwd,pcid-spawner`, and init skips both services

### Requirement: Env file in initfs
The system SHALL generate an `etc/init.env` file in the initfs image when either `boot.initDebug` is `true` or `boot.initSkip` is non-empty.

The file SHALL use `KEY=VALUE` format with one entry per line and a trailing newline. When both options are at defaults, the file SHALL NOT be present in the initfs.

#### Scenario: Config file generated for debug only
- **WHEN** `boot.initDebug` is `true` and `boot.initSkip` is `[]`
- **THEN** `etc/init.env` contains exactly `INIT_LOG_LEVEL=DEBUG\n`

#### Scenario: Config file generated for skip only
- **WHEN** `boot.initDebug` is `false` and `boot.initSkip` is `["hwd"]`
- **THEN** `etc/init.env` contains exactly `INIT_SKIP=hwd\n`

#### Scenario: Config file generated for both
- **WHEN** `boot.initDebug` is `true` and `boot.initSkip` is `["hwd", "pcid-spawner"]`
- **THEN** `etc/init.env` contains `INIT_LOG_LEVEL=DEBUG\nINIT_SKIP=hwd,pcid-spawner\n`

#### Scenario: No config file when defaults
- **WHEN** `boot.initDebug` is `false` and `boot.initSkip` is `[]`
- **THEN** no `etc/init.env` file exists in the initfs image

### Requirement: Bootstrap reads env file from initfs
Bootstrap SHALL be patched to read `/scheme/initfs/etc/init.env` after building the env vector from `sys:env` and before calling `fexec_impl()`.

For each non-empty line in the file, bootstrap SHALL push it as a `&[u8]` entry to the `envs` vector passed to init.

If the file does not exist (openat returns error), bootstrap SHALL proceed silently with no behavior change.

#### Scenario: Env file exists with debug level
- **WHEN** `/scheme/initfs/etc/init.env` exists and contains `INIT_LOG_LEVEL=DEBUG\n`
- **THEN** bootstrap adds `INIT_LOG_LEVEL=DEBUG` to the envs vector, and init's `env::var("INIT_LOG_LEVEL")` returns `"DEBUG"`

#### Scenario: Env file missing
- **WHEN** `/scheme/initfs/etc/init.env` does not exist
- **THEN** bootstrap proceeds with its default env vector (RUST_BACKTRACE=1, LD_LIBRARY_PATH), and init defaults to `INIT_LOG_LEVEL=INFO`

#### Scenario: Env file vars appear after bootstrap defaults
- **WHEN** `/scheme/initfs/etc/init.env` contains env vars
- **THEN** they are pushed to the envs vector after `RUST_BACKTRACE=1` and `LD_LIBRARY_PATH`, so they appear in init's environment alongside the existing vars
