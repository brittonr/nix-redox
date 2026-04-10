## 1. OpenSSL 3.x Package

- [x] 1.1 Add `openssl3-src` flake input pointing to OpenSSL 3.5.x tarball (or GitHub release)
- [x] 1.2 Create `nix/pkgs/userspace/openssl3-redox.nix` — cross-compile OpenSSL 3.x with upstream's 56-line Redox patch (`redox-x86_64` target in `10-main.conf`, `_SC_CLK_TCK` guard)
- [x] 1.3 Build with `no-tests no-unit-test no-shared no-dso` and `make -j1` (upstream notes make/ar bug)
- [x] 1.4 Wire into `nix/flake-modules/packages.nix` and verify `nix build .#openssl3-redox` produces `lib/libssl.a`, `lib/libcrypto.a`, `include/openssl/*.h`

## 2. OpenSSH Package

- [x] 2.1 Add `openssh-src` flake input for OpenSSH 9.8p1 portable tarball from `cdn.openbsd.org`
- [x] 2.2 Copy upstream's 686-line `redox.patch` into `nix/pkgs/patches/openssh-redox.patch`
- [x] 2.3 Create `nix/pkgs/userspace/openssh-redox.nix` — cross-compile OpenSSH with autotools configure, linking against `openssl3-redox`, `zlib`, `zstd-redox`
- [x] 2.4 Configure flags: `--disable-strip --sysconfdir=/etc/ssh --host=${redoxTarget}`, with cross-compile cache variables for functions that can't be runtime-tested
- [x] 2.5 Apply the Redox patch during configure phase, handle `sbin/sshd` → `bin/sshd` move
- [x] 2.6 Install binaries: `ssh`, `sshd`, `ssh-keygen`, `scp`, `sftp`, `sftp-server`
- [x] 2.7 Wire into `nix/flake-modules/packages.nix` and verify `nix build .#openssh-redox` produces all six binaries

## 3. Remove redox-ssh

- [x] 3.1 Delete `nix/pkgs/userspace/redox-ssh.nix`
- [x] 3.2 Remove `redox-ssh-src` flake input from `flake.nix`
- [x] 3.3 Update `nix/flake-modules/packages.nix` — remove commented-out `redox-ssh` definition
- [x] 3.4 Update `assertions.nix` — change `pkgs ? redox-ssh` to `pkgs ? openssh` (or whatever the package name is)
- [x] 3.5 Update `nix/tests/mock-pkgs.nix` and `nix/tests/eval.nix` — replace `redox-ssh` references with `openssh`

## 4. Service Module Updates

- [x] 4.1 Update `services.nix` — change sshd service command from `/bin/sshd -p PORT -k KEY` to `/bin/sshd -D`, change type from `nowait` to `daemon`
- [x] 4.2 Update `generated-files.nix` — add `HostKey` lines for all three key types in `sshd_config`, add `AddressFamily inet`, set `UsePAM no`, set `Subsystem sftp /bin/sftp-server`
- [x] 4.3 Update `generated-files.nix` — remove the old single `hostKeyPath` pattern, use three separate key paths matching OpenSSH convention
- [x] 4.4 Update `services.nix` SSH option types if needed (hostKeyPath becomes less relevant since sshd reads sshd_config directly)

## 5. Host Key Generation

- [x] 5.1 Create a Nix derivation that runs `ssh-keygen` (from host nixpkgs) three times to generate ed25519, rsa, and ecdsa host keys with empty passphrases
- [x] 5.2 Wire generated keys into `generated-files.nix` — include them at `/etc/ssh/ssh_host_{ed25519,rsa,ecdsa}_key` with mode 0600 when SSH is enabled
- [x] 5.3 Verify sshd loads the generated keys on boot (test via serial output or ssh connection)

## 6. SSH Test Profile and VM Test

- [x] 6.1 Create `nix/redox-system/profiles/ssh-test.nix` — networking enabled, SSH enabled, userutils for login, root user with known password, `permitRootLogin = true`
- [x] 6.2 Create `nix/pkgs/infrastructure/ssh-test.nix` — QEMU VM test with `hostfwd=tcp::2222-:22`, waits for sshd via serial, runs `ssh -p 2222 root@localhost` from host
- [x] 6.3 Handle password auth in test — use `sshpass` or `SSH_ASKPASS` trick for non-interactive password entry
- [x] 6.4 Wire `ssh-test` into flake outputs so `nix build .#ssh-test` runs the test
- [x] 6.5 Run end-to-end and verify SSH_TEST:connect:PASS output

## 7. Cleanup and Documentation

- [x] 7.1 Update AGENTS.md with OpenSSH-specific knowledge (build flags, patch provenance, known Redox limitations in the patch)
- [x] 7.2 Verify `nix flake check` passes with new packages and updated assertions
- [x] 7.3 Update napkin with any gotchas discovered during implementation
