## ADDED Requirements

### Requirement: VM integration test for SSH
An automated VM test SHALL boot Redox with SSH enabled, wait for sshd to start, and verify that an SSH client on the host can connect and execute a command.

#### Scenario: End-to-end SSH test passes
- **WHEN** the ssh-test VM boots with `/services/ssh.enable = true`
- **AND** QEMU user-mode networking forwards host port 2222 to guest port 22
- **THEN** the host SHALL be able to run `ssh -p 2222 root@localhost 'echo SSH_WORKS'`
- **AND** the output SHALL contain `SSH_WORKS`
- **AND** the ssh client SHALL exit with status 0

#### Scenario: sshd starts during boot
- **WHEN** the VM boots with SSH enabled
- **THEN** the serial console output SHALL show the sshd service started
- **AND** sshd SHALL be listening on port 22 before the test connects

### Requirement: SSH test profile
An `ssh-test.nix` profile SHALL exist that configures a minimal Redox system with networking and SSH enabled.

#### Scenario: Profile includes required packages
- **WHEN** the ssh-test profile is used
- **THEN** the system SHALL include `ion`, `uutils`, `extrautils`, `netutils`, `netcfg-setup`, `userutils`, and `openssh` packages

#### Scenario: Profile configures SSH and users
- **WHEN** the ssh-test profile is used
- **THEN** `/services/ssh.enable` SHALL be `true`
- **AND** `/services/ssh.permitRootLogin` SHALL be `true`
- **AND** a root user with a known test password SHALL be configured
- **AND** networking mode SHALL be `auto` with QEMU SLiRP DNS/gateway

### Requirement: Test produces machine-readable output
The SSH test runner SHALL produce structured output for CI integration.

#### Scenario: Test output format
- **WHEN** the SSH test completes
- **THEN** it SHALL emit `SSH_TESTS_START` before testing
- **AND** `SSH_TEST:<name>:PASS` or `SSH_TEST:<name>:FAIL:<reason>` for each check
- **AND** `SSH_TESTS_COMPLETE` when finished
