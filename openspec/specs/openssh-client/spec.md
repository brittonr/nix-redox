## ADDED Requirements

### Requirement: ssh client connects to remote servers
The ssh client binary SHALL connect to remote SSH servers with `ssh [user@]host [-p port]` and establish an interactive session.

#### Scenario: Connect and run command
- **WHEN** `ssh root@192.168.1.1 'echo hello'` is executed on Redox
- **THEN** the client SHALL connect to port 22, authenticate, execute the command, print the output, and exit

#### Scenario: Custom port
- **WHEN** `ssh -p 2222 root@192.168.1.1` is executed
- **THEN** the client SHALL connect to port 2222

#### Scenario: Connection refused
- **WHEN** the target host is not listening
- **THEN** the client SHALL print an error and exit with non-zero status

### Requirement: scp and sftp binaries present
The package SHALL include `scp` and `sftp` binaries for file transfer, and `sftp-server` for the server side.

#### Scenario: Binaries installed
- **WHEN** the openssh package is installed
- **THEN** `ssh`, `sshd`, `ssh-keygen`, `scp`, `sftp`, and `sftp-server` SHALL all be present in the output
