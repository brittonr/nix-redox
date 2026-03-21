## ADDED Requirements

### Requirement: VM functional test validates symlink behavior through virtio-fs
A VM functional test SHALL verify end-to-end symlink support through the virtio-fs build bridge. The test SHALL create symlinks on the host side in the shared directory and verify from the Redox guest that symlinks are correctly traversed, stat'd, and listed.

#### Scenario: Read file through a symlink
- **WHEN** the host shared directory contains `target.txt` and a symlink `link.txt → target.txt`
- **THEN** reading `/scheme/shared/link.txt` from the guest returns the contents of `target.txt`

#### Scenario: Stat a symlink reports S_IFLNK
- **WHEN** the guest opens `/scheme/shared/link.txt` with O_STAT
- **THEN** `fstat` reports `st_mode` with S_IFLNK type bits

#### Scenario: Directory listing shows symlink type
- **WHEN** the guest lists a directory containing symlinks
- **THEN** `getdents` reports DirentKind::Symlink (DT_LNK = 10) for symlink entries

#### Scenario: Symlink chain traversal
- **WHEN** `a → b → target.txt` (two-hop symlink chain) exists in the shared directory
- **THEN** reading through `a` resolves both hops and returns the target's contents
