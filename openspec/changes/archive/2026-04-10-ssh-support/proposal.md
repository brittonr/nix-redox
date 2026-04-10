## Why

Redox OS has no encrypted remote shell. The only remote access is a raw TCP netcat listener (`nc -l -e /bin/sh`) with zero authentication or encryption. Upstream Redox has been actively porting OpenSSH 9.8p1 — there's a 686-line Redox patch (dated Sep 2025), an openssl3 recipe in wip/, and a working `server-demo.toml` config that runs sshd with password auth. Our Nix module system already has typed SSH service options, config file generation, and build assertions wired up but nothing plugged in. Porting OpenSSH (matching upstream's direction) gives us a battle-tested SSH implementation instead of reviving the abandoned `redox-ssh` crate.

## What Changes

- **Port OpenSSL 3.x for Redox**: Build OpenSSL 3.5.x with the upstream 56-line Redox patch. We already have OpenSSL 1.1.1 (`openssl-redox.nix`) but OpenSSH 9.8p1 and the rest of upstream are migrating to 3.x. Keep openssl1 for existing dependents (curl, git, libssh2); add openssl3 as a new package.
- **Port OpenSSH 9.8p1**: Cross-compile OpenSSH portable with the upstream 686-line Redox patch. Build against openssl3 + zlib + zstd. Produces `ssh`, `sshd`, `ssh-keygen`, `scp`, `sftp`, `sftp-server` binaries. This replaces the broken `redox-ssh` package.
- **Host key generation**: Generate Ed25519/RSA/ECDSA host keys at build time (deterministic, for dev/test) and place them in `/etc/ssh/`. Match the upstream `server-demo.toml` pattern of first-boot keygen as a future option.
- **Update service module**: Adapt the existing `/services/ssh` typed module to drive OpenSSH's `sshd` (which uses `-D` for foreground, reads `/etc/ssh/sshd_config` natively) instead of the redox-ssh CLI flags.
- **Wire sshd into a test profile**: Create an `ssh-test.nix` profile and VM test that boots Redox, waits for sshd, and connects from the host to verify SSH works end-to-end.
- **Remove redox-ssh**: Delete the broken `redox-ssh.nix` package definition and update assertions to reference the new openssh package.

## Capabilities

### New Capabilities
- `openssh-server`: OpenSSH sshd daemon with Ed25519/RSA/ECDSA host keys, password authentication, PTY allocation, privilege separation disabled (Redox limitation), `sshd_config`-driven configuration.
- `openssh-client`: OpenSSH ssh client, scp, sftp binaries for outbound connections from Redox.
- `openssh-keygen`: ssh-keygen for key generation, plus build-time host key generation for the disk image.
- `openssl3`: OpenSSL 3.x static library cross-compiled for Redox, needed by OpenSSH and as the forward path for other packages migrating from openssl1.
- `ssh-test`: VM integration test validating sshd starts, accepts connections, and executes commands over SSH.

### Modified Capabilities
<!-- No existing spec-level requirements change. The service module plumbing exists
     and generates init scripts and config files — it just needs different CLI args
     for OpenSSH vs redox-ssh. -->

## Impact

- **New packages**: `openssl3-redox` (C library), `openssh-redox` (C application with custom build). Both use `mk-c-library.nix` / custom cross-compilation patterns.
- **Removed packages**: `redox-ssh.nix` deleted, `redox-ssh-src` flake input removed.
- **Dependencies**: OpenSSH needs openssl3 + zlib + zstd (latter two already exist). OpenSSL 3.x needs zlib + zstd.
- **Patches**: Upstream's `redox.patch` for OpenSSH (686 lines) and openssl3 (56 lines) applied during build. Not custom work — directly from the Redox cookbook.
- **Service module**: `/services/ssh` in `services.nix` updated — sshd command changes from `/bin/sshd -p PORT -k KEYPATH` to `/bin/sshd -D` (reads sshd_config). Config file generation in `generated-files.nix` already exists.
- **Init scripts**: sshd service type changes from `nowait` to `daemon` (since `-D` keeps it in foreground).
- **Config files**: `sshd_config` format stays the same (it's already OpenSSH-format). Add host key paths for multiple key types.
- **Existing packages**: `curl-redox.nix`, `git-redox.nix`, `libssh2` stay on openssl1 for now. Migration to openssl3 is a separate change.
