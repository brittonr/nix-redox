## ADDED Requirements

### Requirement: VM test validates /etc/static after boot
A functional test profile MUST verify that after `snix system switch`, `/etc/static` exists and is a symlink pointing to a nix store path.

#### Scenario: /etc/static exists after switch
- **WHEN** the test runs `snix system switch` on a live Redox VM
- **THEN** `/etc/static` is a symlink to a store path

### Requirement: VM test validates /run/current-system after switch
A functional test profile MUST verify that after `snix system switch`, `/run/current-system` exists.

#### Scenario: /run/current-system exists after switch
- **WHEN** the test runs `snix system switch` on a live Redox VM
- **THEN** `/run/current-system` is a symlink

### Requirement: VM test validates per-file symlinks
A functional test profile MUST verify that at least one managed etc file (e.g. `/etc/hostname`) is a symlink through `/etc/static`.

#### Scenario: Managed file symlinked through /etc/static
- **WHEN** the test inspects `/etc/hostname` after switch
- **THEN** it is a symlink whose target passes through `/etc/static`

### Requirement: VM test validates GC root
A functional test profile MUST verify that `/nix/var/nix/gcroots/current-system` exists after activation.

#### Scenario: GC root symlink present
- **WHEN** the test inspects the filesystem after switch
- **THEN** `/nix/var/nix/gcroots/current-system` exists as a symlink
