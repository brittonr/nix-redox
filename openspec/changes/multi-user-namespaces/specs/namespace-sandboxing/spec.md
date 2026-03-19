## MODIFIED Requirements

### Requirement: Per-user namespace configuration
The module system SHALL generate `/etc/login_schemes.toml` with per-user scheme lists derived from the users module, replacing the current hardcoded root-only entry. Each user with a `schemes` attribute SHALL get a `[user_schemes.<name>]` section. The file format SHALL match the upstream userutils `LoginConfig` serde struct: a TOML file with a `[user_schemes]` table of tables, each containing a `schemes` array of strings.

#### Scenario: Multiple users with different scheme lists
- **WHEN** root is configured with full schemes and user is configured with restricted schemes
- **THEN** `/etc/login_schemes.toml` SHALL contain both `[user_schemes.root]` and `[user_schemes.user]` sections with their respective scheme lists

#### Scenario: Generated TOML parses correctly
- **WHEN** the generated `login_schemes.toml` is parsed by `toml::from_str::<LoginConfig>()`
- **THEN** parsing SHALL succeed and the scheme lists SHALL match the declared values
