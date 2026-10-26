## ADDED Requirements

### Requirement: Mutable inode mappings are isolated

File-backed mappings of mutable files SHALL NOT expose pages belonging to a
different file after the inode's filesystem tree node is recycled.

#### Scenario: Builder writes and maps a temporary object

- **WHEN** an unsandboxed builder writes an object under `$TMPDIR`, unmaps it,
  and a later file reuses the same tree node
- **THEN** a subsequent mapping of the new file must contain only that file's
  bytes, and linking the object must not report a truncated section table.

#### Scenario: Store mappings stay zero-copy

- **WHEN** a process maps a read-only store path
- **THEN** the mapping may remain file-backed and zero-copy, because store
  paths are immutable.
