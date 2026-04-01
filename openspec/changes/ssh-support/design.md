## Context

Upstream Redox has an active OpenSSH 9.8p1 port. The evidence:

- `recipes/net/openssh/recipe.toml` — not in wip/, uses `openssl3` + `zlib` + `zstd`
- `recipes/net/openssh/redox.patch` — 686 lines, timestamps Sep 2025, by Ribbon/Wildan Mubarok
- `config/x86_64/server-demo.toml` — deploys sshd under rustysd with password auth, first-boot keygen
- Feb 2026 news: OpenSSL 1.x → 3.x migration underway across ecosystem (nginx, Git, curl, COSMIC Store)

The patch addresses known Redox limitations:
- `closefrom()` not implemented → removed from 10+ callsites
- `poll()` with timeout -1 gets stuck → changed to 1000ms timeout
- No `resolv.h` → stub with minimal `__res_state` and `HEADER` structs
- No `utmpx.h` → stub with empty function implementations
- `initgroups`/`setgroups` broken → `#ifndef __redox__` guards
- `privsep_chroot` disabled (no chroot on Redox)
- `sshkey_shield_private` disabled (mmap/mprotect issue)
- `pty_setowner` disabled (no ownership model for PTYs on Redox)

Our current state:
- `openssl-redox.nix` builds OpenSSL 1.1.1 (Redox fork, `redox-v1` branch) — works, used by curl/git
- `zlib.nix` and `zstd-redox.nix` — already cross-compiled
- `services.nix` has typed SSH module with port/listenAddress/hostKeyPath/permitRootLogin/authorizedKeysPath
- `generated-files.nix` produces `/etc/ssh/sshd_config` and `/etc/ssh/authorized_keys`
- `assertions.nix` validates ssh.enable requires the ssh package + networking
- `redox-ssh.nix` exists but is commented out — `rustc-serialize` doesn't compile

## Goals / Non-Goals

**Goals:**
- `ssh root@redox-host` from a standard OpenSSH client connects and provides an interactive shell
- Multiple host key types (Ed25519, RSA, ECDSA) matching upstream's `server-demo.toml` pattern
- Password authentication against `/etc/shadow` (Argon2id or system PAM, whatever OpenSSH's native mechanism supports)
- sshd starts automatically via init when `/services/ssh.enable = true`
- OpenSSL 3.x available as a new package for forward compatibility
- VM test verifies SSH end-to-end

**Non-Goals:**
- Migrating existing packages (curl, git, libssh2) from openssl1 to openssl3 — separate change
- Privilege separation (requires chroot, not available on Redox)
- DNS-based host verification (no `resolv.h` / resolver on Redox)
- SFTP subsystem testing (binary will be built but not validated in this change)
- PAM integration (Redox has no PAM)
- IPv6 (upstream patch explicitly sets `AddressFamily inet`)

## Decisions

### 1. OpenSSH over redox-ssh

**Decision**: Port OpenSSH 9.8p1 using upstream's existing Redox patch. Delete `redox-ssh`.

**Rationale**: The `redox-ssh` crate is abandoned (~2017, single commit, depends on deprecated crates that don't compile). OpenSSH is actively being ported by upstream Redox developers with a working 686-line patch. OpenSSH gives us a battle-tested SSH implementation that every client already speaks. The upstream `server-demo.toml` proves the approach works.

**Alternative considered**: Revive `redox-ssh` by replacing `rustc-serialize`/`rust-crypto` with RustCrypto crates. Rejected — ~2200 lines of mechanical replacement for a crate that implements a fraction of SSH2 (no SFTP, no agent forwarding, no config file, custom key format), vs. applying an existing 686-line patch to the real OpenSSH.

### 2. OpenSSL 3.x as a new package alongside 1.x

**Decision**: Add `openssl3-redox.nix` as a new package. Keep `openssl-redox.nix` (1.1.1) for existing dependents.

**Rationale**: OpenSSH 9.8p1 needs OpenSSL 3.x (the `Configure` target names changed, APIs differ). Upstream is migrating everything to 3.x but we don't need to do that all at once. Two OpenSSL packages coexist — they produce different `.a` files and headers, no conflict for static linking.

The upstream openssl3 recipe uses vanilla OpenSSL 3.5.x from GitHub releases with a 56-line patch (Redox target detection in `10-main.conf`, `_SC_CLK_TCK` guard). Much cleaner than the `redox-v1` branch fork of 1.1.1.

### 3. Build system: autotools cross-compilation

**Decision**: Use OpenSSH's `configure` with cross-compilation flags, similar to how we build other autotools packages (gettext, ncurses, readline). Apply the upstream `redox.patch` as-is.

**Rationale**: The upstream recipe uses `DYNAMIC_INIT` + `cookbook_configure` which maps to standard autotools cross-compilation. We translate this to our `mk-c-library.nix` / CC wrapper pattern. The Redox patch already modifies `configure` to recognize the `*-*-redox` target.

Key build details from upstream recipe:
- `--disable-strip --sysconfdir=/etc/ssh`
- `CFLAGS += -DSYSTEMD_NOTIFY=1` (enables a notify path, may be relevant for init integration)
- Post-build: move `sbin/sshd` → `bin/sshd` (Redox has no sbin)
- Host keys generated separately (keygen script, not during build)

### 4. Host key generation

**Decision**: Generate deterministic host keys during the Nix build and bake them into the disk image at `/etc/ssh/ssh_host_{ed25519,rsa,ecdsa}_key`. Matching upstream's key types.

**Rationale**: The upstream `server-demo.toml` uses a first-boot bash script (`keygen.sh`) that runs `ssh-keygen` for each key type. We can't reliably run oneshot scripts during boot (known issue — see napkin). Build-time generation is deterministic and guaranteed to be present. Keys are in the Nix store (not secret) — acceptable for dev/test.

For the build, we can use the host's `ssh-keygen` (from nixpkgs' openssh) since the key format is platform-independent.

### 5. sshd_config driven configuration

**Decision**: sshd reads `/etc/ssh/sshd_config` natively. The service module generates this file (already does in `generated-files.nix`). sshd runs with `-D` (don't detach) so the init system manages the process.

**Rationale**: OpenSSH's sshd is config-file-driven, not CLI-flag-driven like redox-ssh was. The existing `generated-files.nix` already produces a valid `sshd_config`. We just need to:
- Update the sshd service from `nowait` to `daemon` type (init waits for readiness)
- Change the command from `/bin/sshd -p PORT -k KEY` to `/bin/sshd -D`
- Add `HostKey` lines for each key type in `sshd_config`
- Add `AddressFamily inet` (no IPv6 on Redox)
- Set `PermitEmptyPasswords yes` if needed (upstream demo does this)

### 6. Test strategy

**Decision**: QEMU VM test with user-mode networking and port forwarding (host 2222 → guest 22). Host-side `ssh` connects to the guest and runs a command.

**Rationale**: Same pattern as `network-test.nix`. QEMU SLiRP networking supports TCP port forwarding via `-net user,hostfwd=tcp::2222-:22`. The test waits for serial output indicating sshd started, then runs the SSH connection from the host.

OpenSSH client options for automation: `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes` or use `sshpass` for password auth in the test.

## Risks / Trade-offs

- **[Risk] OpenSSL 3.x build complexity** → Mitigation: Upstream patch is only 56 lines. We already build OpenSSL 1.x. The 3.x `Configure` script is similar. `make -j1` required (upstream notes a make/ar bug).
- **[Risk] OpenSSH autotools configure may fail cross-compiling** → Mitigation: The upstream recipe works. Our CC wrapper pattern handles cross-compilation. May need `ac_cv_*` cache variables for functions that can't be tested during cross-compile.
- **[Risk] poll() with 1000ms timeout burns CPU** → Accepted trade-off. The upstream patch uses this. It's the known workaround for Redox's broken `poll()`. Only affects sshd's monitor process.
- **[Risk] No privilege separation** → Accepted. The upstream patch disables it (`privsep_chroot = 0`). Redox has no chroot. sshd runs as root without sandboxing. Development tool, not production hardened.
- **[Risk] Password auth on Redox** → OpenSSH can do PAM or its own password checking. Redox has no PAM. Need to verify OpenSSH falls back to crypt()/`/etc/shadow` or if we need to configure `UsePAM no` (likely already the case since configure won't find PAM).
- **[Risk] closefrom() removal may leak FDs** → Accepted. The upstream patch removes all `closefrom()` calls. Redox doesn't implement it. FD leaks possible but not catastrophic for development use.

## Open Questions

- Does OpenSSH's `configure` detect Redox's password checking mechanism? We may need `UsePAM no` and explicit `PasswordAuthentication yes` in sshd_config. The upstream demo config has both.
- The upstream recipe references `DYNAMIC_INIT` — does OpenSSH need dynamic linking on Redox, or can we build fully static? Static is simpler for our setup. The recipe has a dynamic/static branch.
- The upstream `server-demo.toml` sets `PermitEmptyPasswords yes` — should we default to this? Our user module generates Argon2id hashes, so users have real passwords. Probably set to `no` and only allow hashed passwords.
