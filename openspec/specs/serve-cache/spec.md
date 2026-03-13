## ADDED Requirements

### Requirement: Standalone cache server command
The system SHALL provide a `serve-cache` command (available as `nix run .#serve-cache`) that serves a binary cache directory over HTTP.

#### Scenario: Default invocation
- **WHEN** user runs `nix run .#serve-cache`
- **THEN** an HTTP server starts on port 18080 serving the default cache directory

#### Scenario: Custom port and directory
- **WHEN** user runs `serve-cache --port 9090 --dir /path/to/cache`
- **THEN** the server starts on port 9090 serving files from `/path/to/cache`

#### Scenario: Cache verification at startup
- **WHEN** the server starts
- **THEN** it checks for `nix-cache-info` or `packages.json` in the directory and prints a warning if neither exists

### Requirement: Flake app registration
The system SHALL register `serve-cache` as a flake app so it can be run via `nix run .#serve-cache`.

#### Scenario: App is listed
- **WHEN** user runs `nix flake show` on the project
- **THEN** `serve-cache` appears in the apps output
