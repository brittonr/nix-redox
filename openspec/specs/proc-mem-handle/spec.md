## ADDED Requirements

### Requirement: Open memory handle via proc scheme
The kernel proc: scheme SHALL accept the path `mem` when opening `proc:<pid>/mem`, providing read/write access to the target process's virtual address space.

#### Scenario: Open memory for a process
- **WHEN** userspace opens `proc:<pid>/mem` with read+write
- **THEN** the kernel returns a seekable file descriptor backed by the target's AddrSpace

### Requirement: Read target memory via seek and read
The kernel SHALL support seeking to a virtual address and reading bytes from the target process's memory. Virtual addresses SHALL be translated through the target's page tables.

#### Scenario: Read mapped memory
- **WHEN** userspace seeks to a mapped address and reads N bytes
- **THEN** the kernel translates the virtual address, copies N bytes from the target's physical memory, and returns them

#### Scenario: Read unmapped memory
- **WHEN** userspace seeks to an unmapped address and reads
- **THEN** the kernel returns EFAULT

#### Scenario: Read across page boundary
- **WHEN** userspace reads a range that spans two pages
- **THEN** the kernel translates each page separately and returns the concatenated bytes

### Requirement: Write target memory via seek and write
The kernel SHALL support seeking to a virtual address and writing bytes to the target process's memory. This enables software breakpoint patching (writing 0xCC for int3).

#### Scenario: Write to mapped writable memory
- **WHEN** userspace seeks to a writable mapped address and writes bytes
- **THEN** the kernel writes the bytes to the target's physical memory

#### Scenario: Write to read-only memory
- **WHEN** userspace seeks to a read-only mapped address and writes
- **THEN** the kernel returns EACCES (or temporarily upgrades permissions for debugger use)

### Requirement: Target must be stopped for memory access
The kernel SHALL stop the target process before performing memory reads or writes, using the existing `try_stop_context()` mechanism. This prevents page table changes during access.

#### Scenario: Memory read on running process
- **WHEN** userspace reads memory of a running process
- **THEN** the kernel stops the target, reads memory, then restores previous status
