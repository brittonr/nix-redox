## ADDED Requirements

### Requirement: FileIoWorker file cache is bounded
The FileIoWorker's internal file descriptor cache SHALL hold at most 64 entries. When inserting a new entry would exceed this limit, the oldest entry (by BTreeMap ordering) SHALL be removed first.

#### Scenario: Cache below limit
- **WHEN** the cache has fewer than 64 entries
- **THEN** new files are inserted without eviction

#### Scenario: Cache at limit
- **WHEN** the cache has 64 entries and a new file is opened
- **THEN** the first entry (lexicographically lowest path) is removed
- **THEN** the new file is inserted

#### Scenario: Re-opening evicted file
- **WHEN** a previously cached file was evicted and is requested again
- **THEN** the worker re-opens the file from the filesystem
- **THEN** the read succeeds with correct data
