## ADDED Requirements

### Requirement: Declarative etc file injection
The `/environment` module SHALL provide an `etc` option that accepts an attrset of file entries. Each entry SHALL specify a destination path (relative to `/`) as the key and file content via `text` or `source` with an optional `mode`.

#### Scenario: Profile injects a custom etc file via text
- **WHEN** a profile sets `"/environment".etc."etc/motd" = { text = "Welcome!"; mode = "0644"; }`
- **THEN** the built root tree SHALL contain `/etc/motd` with content "Welcome!" and mode 0644

#### Scenario: Profile injects a file via source derivation
- **WHEN** a profile sets `"/environment".etc."etc/shadow" = { source = shadowDerivation; mode = "0600"; }`
- **THEN** the built root tree SHALL copy the file from the derivation path to `/etc/shadow` with mode 0600

#### Scenario: Default mode applied when omitted
- **WHEN** a profile sets `"/environment".etc."etc/banner" = { text = "hello"; }` without a mode
- **THEN** the file SHALL be created with the default mode "0644"

### Requirement: User etc entries override built-in generated files
When an `environment.etc` entry has the same key as a hardcoded generated file in `generated-files.nix`, the user's entry SHALL take precedence.

#### Scenario: Override built-in hostname file
- **WHEN** the build module generates `etc/hostname` with content from the `/time` module AND the profile sets `"/environment".etc."etc/hostname" = { text = "custom-host"; }`
- **THEN** the root tree SHALL contain `/etc/hostname` with content "custom-host", not the module-generated value

### Requirement: Environment etc entries tracked in manifest
Files injected via `environment.etc` SHALL appear in the manifest's `files` section with their blake3 hashes, enabling `snix system verify` to validate them.

#### Scenario: Verify detects modified etc file
- **WHEN** a system is built with `"/environment".etc."etc/motd" = { text = "Welcome!"; }` AND the file is later modified on disk
- **THEN** `snix system verify` SHALL report a hash mismatch for `etc/motd`

### Requirement: Environment etc entries support subdirectory creation
When an `environment.etc` entry path contains subdirectories that don't exist, the build SHALL create them.

#### Scenario: Nested path creation
- **WHEN** a profile sets `"/environment".etc."etc/myapp/config.toml" = { text = "[app]\nname = \"test\""; }`
- **THEN** the root tree SHALL create `/etc/myapp/` directory and place `config.toml` inside it

### Requirement: Empty etc attrset has no effect
When `environment.etc` is empty (the default), the build SHALL produce the same output as before this feature was added.

#### Scenario: Default empty etc
- **WHEN** no profile sets any `environment.etc` entries
- **THEN** the root tree SHALL contain only the hardcoded generated files from `generated-files.nix`
