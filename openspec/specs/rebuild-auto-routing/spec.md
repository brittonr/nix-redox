## ADDED Requirements

### Requirement: Auto-route to bridge when packages changed and bridge available
`snix system rebuild` SHALL automatically use the bridge path when the parsed configuration contains package changes and `/scheme/shared/requests` is a directory.

#### Scenario: Package change with bridge available
- **WHEN** configuration.nix contains `packages = [ "ripgrep" ]`
- **AND** `/scheme/shared/requests` exists as a directory
- **AND** neither `--bridge` nor `--local` flags are passed
- **THEN** the rebuild uses the bridge path (sends request to host, polls for response)

#### Scenario: Config-only change with bridge available
- **WHEN** configuration.nix changes only `hostname`
- **AND** `/scheme/shared/requests` exists as a directory
- **AND** neither `--bridge` nor `--local` flags are passed
- **THEN** the rebuild uses the local path (no bridge round-trip)

#### Scenario: Config-only change without bridge
- **WHEN** configuration.nix changes only `hostname`
- **AND** `/scheme/shared/requests` does NOT exist
- **THEN** the rebuild uses the local path and succeeds

### Requirement: Error on package changes without bridge
`snix system rebuild` SHALL report a clear error when package changes are detected but no bridge is available.

#### Scenario: Package change without bridge
- **WHEN** configuration.nix contains `packages = [ "ripgrep" ]`
- **AND** `/scheme/shared/requests` does NOT exist
- **AND** `--local` flag is NOT passed
- **THEN** the command exits with an error
- **AND** the error message explains that package changes require the bridge
- **AND** the error message includes instructions for starting the VM with shared filesystem

### Requirement: Explicit --bridge flag overrides auto-detection
The `--bridge` flag SHALL force the bridge path regardless of config content.

#### Scenario: Force bridge for config-only change
- **WHEN** configuration.nix changes only `hostname`
- **AND** `--bridge` flag is passed
- **THEN** the rebuild uses the bridge path

### Requirement: Explicit --local flag forces local path
The `--local` flag SHALL force the local rebuild path, including local package resolution.

#### Scenario: Force local for package change
- **WHEN** configuration.nix contains `packages = [ "ripgrep" ]`
- **AND** `--local` flag is passed
- **THEN** the rebuild uses the local path with JSON index resolution
- **AND** no error about missing bridge is shown

### Requirement: Empty package list treated as no package change
An empty `packages = []` in configuration.nix SHALL be treated as "no package change" (same as omitting the packages field).

#### Scenario: Empty packages list
- **WHEN** configuration.nix contains `packages = []`
- **AND** no bridge is available
- **THEN** the rebuild uses the local path and succeeds (no package error)
