## ADDED Requirements

### Requirement: Toplevel contains activate script
The `toplevel` derivation SHALL include an executable `activate` script at `$out/activate` that performs all steps needed to switch the running system to this configuration.

#### Scenario: Activate script exists and is executable
- **WHEN** the toplevel derivation is built
- **THEN** `$out/activate` exists with mode 0755

#### Scenario: Activate script updates etc static
- **WHEN** `$out/activate` is executed
- **THEN** `/etc/static` is atomically switched to point at the new etc derivation

#### Scenario: Activate script runs activation scripts
- **WHEN** `$out/activate` is executed
- **THEN** all scripts in `$out/etc/redox-system/activation.d/` are executed in dependency order

#### Scenario: Activate script updates current-system link
- **WHEN** `$out/activate` is executed
- **THEN** `/run/current-system` is a symlink to the new toplevel derivation

### Requirement: Standalone etc derivation
The build module SHALL produce a standalone etc derivation at `$toplevel/etc` containing all generated configuration files as a symlink farm. This derivation MUST be usable independently of the rootTree for live configuration updates.

#### Scenario: Etc derivation contains generated files
- **WHEN** the toplevel is built
- **THEN** `$out/etc/` contains symlinks for all files from `allGeneratedFiles`

#### Scenario: Etc derivation matches rootTree etc
- **WHEN** both rootTree and the etc derivation are built
- **THEN** the file contents are identical

### Requirement: Etc static symlink indirection
Activation SHALL manage `/etc` files through an `/etc/static` indirection layer. Each managed file at `/etc/foo` MUST be a symlink to `/etc/static/foo`, and `/etc/static` MUST point to the current etc derivation.

#### Scenario: Fresh activation creates symlinks
- **WHEN** activation runs for the first time
- **THEN** `/etc/static` points to `$toplevel/etc`
- **THEN** managed files in `/etc/` are symlinks through `/etc/static`

#### Scenario: Activation updates symlinks atomically
- **WHEN** a new toplevel is activated
- **THEN** `/etc/static` is updated to point to the new etc derivation
- **THEN** existing symlinks in `/etc/` resolve to the new files

### Requirement: GC root management
Activation SHALL create a GC root at `/nix/var/nix/gcroots/current-system` pointing to `/run/current-system` to prevent the active system configuration from being garbage collected.

#### Scenario: GC root exists after activation
- **WHEN** activation completes
- **THEN** `/nix/var/nix/gcroots/current-system` is a symlink to `/run/current-system`

#### Scenario: Active system survives garbage collection
- **WHEN** `nix-collect-garbage` runs
- **THEN** the store paths referenced by `/run/current-system` are NOT deleted
