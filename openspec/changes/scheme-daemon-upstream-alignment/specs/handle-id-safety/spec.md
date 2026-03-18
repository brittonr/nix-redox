## ADDED Requirements

### Requirement: Handle IDs wrap within valid range
All scheme daemons SHALL allocate handle IDs in the range `1..=usize::MAX - 4096`. When the counter exceeds this range, it SHALL wrap back to 1.

#### Scenario: Normal allocation
- **WHEN** a new handle is opened
- **THEN** the daemon returns a unique ID in the range `1..=usize::MAX - 4096`

#### Scenario: Counter wraps
- **WHEN** the handle ID counter exceeds `usize::MAX - 4096`
- **THEN** the counter wraps to 1 and continues allocating

### Requirement: Handle IDs avoid collisions with open handles
When a candidate handle ID collides with an existing open handle, the daemon SHALL skip it and try the next ID.

#### Scenario: Collision with open handle
- **WHEN** the next candidate ID is already in the handle map
- **THEN** the daemon increments and retries until finding an unused ID

#### Scenario: No collision
- **WHEN** the next candidate ID is not in the handle map
- **THEN** the daemon uses that ID immediately

### Requirement: Handle ID counter is per-instance
Each scheme handler instance SHALL maintain its own handle ID counter as an instance field, not a global static.

#### Scenario: build_proxy instance counter
- **WHEN** a BuildFsHandler is created
- **THEN** it has its own `next_id` field starting at 1
- **THEN** the global `static NEXT_HANDLE_ID` is removed
