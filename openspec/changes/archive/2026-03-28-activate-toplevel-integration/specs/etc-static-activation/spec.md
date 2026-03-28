## ADDED Requirements

### Requirement: Manifest includes toplevel and etc store paths
The system manifest SHALL include a `toplevel` field containing the toplevel store path and an `etcSource` field containing the etc derivation store path.

#### Scenario: Manifest has toplevel path
- **WHEN** a system is built
- **THEN** `manifest.json` contains `toplevel` with a valid `/nix/store/...` path

#### Scenario: Manifest has etc source path
- **WHEN** a system is built
- **THEN** `manifest.json` contains `etcSource` with a valid `/nix/store/...` path pointing to the etc derivation

### Requirement: Activate creates /etc/static symlink
During activation, the Rust activate MUST create or update `/etc/static` as a symlink pointing to the new manifest's `etcSource` path.

#### Scenario: Fresh system — /etc/static does not exist
- **WHEN** activation runs and `/etc/static` does not exist
- **THEN** `/etc/static` is created as a symlink to the etc derivation

#### Scenario: Existing system — /etc/static already exists
- **WHEN** activation runs and `/etc/static` already points to an old etc derivation
- **THEN** `/etc/static` is atomically updated to point to the new etc derivation

### Requirement: Activate creates per-file symlinks through /etc/static
During activation, for each file in the etc derivation that has a corresponding path under `/etc/`, the activate MUST ensure `/etc/<path>` is a symlink to `/etc/static/<path>`.

#### Scenario: New managed file
- **WHEN** the new etc derivation adds `etc/newfile.conf`
- **THEN** `/etc/newfile.conf` is a symlink to `/etc/static/etc/newfile.conf`

#### Scenario: Stale symlink cleanup
- **WHEN** the old etc derivation had `etc/removed.conf` but the new one does not
- **THEN** if `/etc/removed.conf` is a symlink through `/etc/static`, it is removed

### Requirement: Activate creates /run/current-system
During activation, the Rust activate MUST create `/run/current-system` as a symlink pointing to the toplevel store path from the new manifest.

#### Scenario: /run/current-system created
- **WHEN** activation completes
- **THEN** `/run/current-system` is a symlink to the toplevel store path

### Requirement: Activate creates filesystem GC root
During activation, the Rust activate MUST create `/nix/var/nix/gcroots/current-system` as a symlink to `/run/current-system`.

#### Scenario: GC root exists after activation
- **WHEN** activation completes
- **THEN** `/nix/var/nix/gcroots/current-system` is a symlink to `/run/current-system`
