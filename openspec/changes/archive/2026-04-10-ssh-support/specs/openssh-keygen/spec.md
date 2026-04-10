## ADDED Requirements

### Requirement: ssh-keygen generates keys
The ssh-keygen binary SHALL generate SSH key pairs of the requested type.

#### Scenario: Generate Ed25519 key
- **WHEN** `ssh-keygen -t ed25519 -f /path/key -N ""` is executed
- **THEN** it SHALL create `/path/key` (private) and `/path/key.pub` (public)

#### Scenario: Generate RSA key
- **WHEN** `ssh-keygen -t rsa -f /path/key -N ""` is executed
- **THEN** it SHALL create an RSA key pair at the specified path

#### Scenario: Generate ECDSA key
- **WHEN** `ssh-keygen -t ecdsa -f /path/key -N ""` is executed
- **THEN** it SHALL create an ECDSA key pair at the specified path

### Requirement: Build-time host key generation
The Nix build system SHALL generate host keys during the disk image build when SSH is enabled.

#### Scenario: SSH enabled generates three key types
- **WHEN** a profile sets `/services/ssh.enable = true`
- **THEN** the disk image SHALL contain:
  - `/etc/ssh/ssh_host_ed25519_key` (mode 0600)
  - `/etc/ssh/ssh_host_rsa_key` (mode 0600)
  - `/etc/ssh/ssh_host_ecdsa_key` (mode 0600)
- **AND** corresponding `.pub` files for each

#### Scenario: Keys generated with host ssh-keygen
- **WHEN** the build runs on the Nix host
- **THEN** host key generation SHALL use the host's `ssh-keygen` binary (from nixpkgs)
- **AND** the generated keys SHALL be in standard OpenSSH format readable by the cross-compiled sshd

#### Scenario: SSH disabled skips key generation
- **WHEN** SSH is not enabled in the profile
- **THEN** no host keys SHALL be generated or included
