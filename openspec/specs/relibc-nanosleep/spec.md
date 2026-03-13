## ADDED Requirements

### Requirement: nanosleep completes within bounded time
relibc's `nanosleep()` SHALL return after the requested duration elapses (within reasonable scheduling jitter). The function MUST NOT hang indefinitely. The implementation SHALL use the Redox time scheme (`/scheme/time/`) for blocking waits.

#### Scenario: One-second sleep returns
- **WHEN** a program calls `nanosleep()` with a 1-second duration
- **THEN** the call returns within 2 seconds (1s sleep + 1s scheduling tolerance)

#### Scenario: Sub-second sleep returns
- **WHEN** a program calls `nanosleep()` with a 100ms duration
- **THEN** the call returns within 500ms

#### Scenario: Zero-duration sleep returns immediately
- **WHEN** a program calls `nanosleep()` with tv_sec=0 and tv_nsec=0
- **THEN** the call returns immediately (yields but does not block)

### Requirement: usleep and sleep work via nanosleep
The libc `sleep()` and `usleep()` functions SHALL complete in bounded time by delegating to the fixed `nanosleep()` implementation.

#### Scenario: sleep(1) completes
- **WHEN** a C or Rust program calls `sleep(1)`
- **THEN** the call returns after approximately 1 second

#### Scenario: usleep(500000) completes
- **WHEN** a program calls `usleep(500000)` (500ms)
- **THEN** the call returns after approximately 500ms

### Requirement: Rust std::thread::sleep works
`std::thread::sleep(Duration)` SHALL complete in bounded time on Redox. This depends on the underlying `nanosleep()` fix.

#### Scenario: Thread sleep 1 second
- **WHEN** a Rust program calls `std::thread::sleep(Duration::from_secs(1))`
- **THEN** the call returns after approximately 1 second

#### Scenario: Thread sleep used in timeout loop
- **WHEN** a Rust program uses `thread::sleep` in a polling loop with a 100ms interval
- **THEN** each iteration advances `Instant::now()` by at least 50ms

### Requirement: clock_gettime monotonic advances
`clock_gettime(CLOCK_MONOTONIC)` SHALL return monotonically increasing values. `Instant::now()` in Rust SHALL reflect real elapsed time.

#### Scenario: Monotonic clock advances between calls
- **WHEN** a program reads `CLOCK_MONOTONIC`, does work, then reads again
- **THEN** the second reading is greater than or equal to the first

#### Scenario: Instant elapsed reflects real time
- **WHEN** a Rust program records `Instant::now()`, waits via a busy loop for observable time, then checks `elapsed()`
- **THEN** `elapsed()` returns a non-zero duration

### Requirement: Patch delivered as Python script
The fix SHALL be implemented as `patch-relibc-nanosleep.py` following the existing `patch-relibc-*.py` pattern. The patch script SHALL be idempotent (safe to run multiple times).

#### Scenario: Patch applies cleanly
- **WHEN** `patch-relibc-nanosleep.py` runs against the relibc source tree
- **THEN** it modifies the nanosleep implementation and exits 0

#### Scenario: Patch is idempotent
- **WHEN** `patch-relibc-nanosleep.py` runs twice on the same source tree
- **THEN** the second run detects existing changes and skips (exits 0)
