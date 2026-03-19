## ADDED Requirements

### Requirement: Multi-user test profile
A test profile SHALL exist that includes userutils, configures root (uid 0) and user (uid 1000), starts the sudod daemon, and runs the multi-user test script at boot. The profile SHALL declare per-user scheme lists: root gets full access, user gets restricted access.

#### Scenario: Profile boots and runs tests
- **WHEN** the multi-user test profile is built and booted
- **THEN** the VM SHALL boot to completion, execute the multi-user test script, and emit `FUNC_TESTS_COMPLETE`

#### Scenario: Profile includes userutils binaries
- **WHEN** the profile is built
- **THEN** the root tree SHALL contain `/bin/login`, `/bin/su`, `/bin/sudo`, `/bin/id`, `/bin/getty`

### Requirement: Multi-user test script
A test script SHALL run inside the VM at boot and validate: user identity (`id`, `whoami`), file ownership (write to own home, denied write to other homes), and scheme namespace visibility (`ls :` output differs between root and restricted user).

#### Scenario: Identity tests pass
- **WHEN** the test script runs `id -u` as root
- **THEN** it SHALL emit `FUNC_TEST:root-uid:PASS`
- **WHEN** the test script runs `id -u` as user 1000
- **THEN** it SHALL emit `FUNC_TEST:user-uid:PASS`

#### Scenario: File ownership tests pass
- **WHEN** the test script attempts to write to `/home/user/` as uid 1000
- **THEN** it SHALL emit `FUNC_TEST:user-home-write:PASS`
- **WHEN** the test script attempts to write to `/root/` as uid 1000
- **THEN** it SHALL emit `FUNC_TEST:user-root-denied:PASS`

#### Scenario: Namespace isolation tests pass
- **WHEN** the test script lists schemes as a restricted user
- **THEN** kernel-only schemes (`irq`, `sys`, `memory`) SHALL be absent from the output
- **AND** it SHALL emit `FUNC_TEST:user-namespace-restricted:PASS`

### Requirement: Test harness integration
The multi-user test script SHALL follow the existing test protocol (`FUNC_TEST:<name>:PASS/FAIL/SKIP`), be installable as a test-scripts/*.ion file, and be runnable from the functional-test harness. Tests that require userutils SHALL skip gracefully when userutils is not installed.

#### Scenario: Tests skip without userutils
- **WHEN** the test script runs on a profile without userutils
- **THEN** all multi-user tests SHALL emit `FUNC_TEST:<name>:SKIP` and not fail
