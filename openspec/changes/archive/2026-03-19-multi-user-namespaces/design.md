## Context

The upstream userutils `login` binary already implements per-user namespace creation:
1. Reads `/etc/login_schemes.toml` — per-user scheme list overrides
2. Falls back to `DEFAULT_SCHEMES` — 26 hardcoded schemes
3. Calls `mkns()` — kernel creates a new namespace with only the listed schemes
4. Calls `setns()` — switches the process into the restricted namespace
5. Spawns the user's shell inside that namespace

The `sudo` binary doubles as a scheme daemon (`--daemon` mode):
1. Registers `sudo:` scheme
2. Clients open `/scheme/sudo` and write their password
3. Daemon verifies password via `redox_users` (reads `/etc/shadow`)
4. Checks `sudo` group membership
5. On success, accepts a `sendfd` with the caller's proc fd
6. Calls `SetResugid(0,0,0,0,0,0)` on the caller's process — sets all UIDs/GIDs to root

`su` opens `/scheme/sudo/su` — similar flow but authenticates with root's password.

`id` reads uid/gid/euid/egid from the kernel. `whoami` is a symlink to `id -un`.

Our module system already generates:
- `/etc/passwd`, `/etc/group`, `/etc/shadow` (Argon2id hashed)
- `/etc/login_schemes.toml` (only for root currently)
- `/etc/security/namespaces`, `/etc/security/policy`, `/etc/security/setuid`
- `sudod` service (started with `sudo --daemon`)
- Home directory ownership via `redoxfs-ar --chown`

What's missing: per-user login_schemes.toml entries, any runtime validation, and
the generated security config files have no consumers (they're for future use).

## Goals / Non-Goals

**Goals:**
- Per-user scheme list configuration in the module system — each user declared in `users.nix` gets a `schemes` option that flows into `login_schemes.toml`
- Default scheme lists differentiate root (full access) from regular users (restricted — no `irq`, `sys`, `memory`, `serio`)
- VM test suite that boots with userutils, logs in as non-root user, and validates: namespace isolation (restricted schemes not visible), file ownership enforcement (can't write to `/root`), `id`/`whoami` returning correct uid, `su`/`sudo` escalation through the scheme daemon
- All tests run through the existing functional-test harness and test script infrastructure

**Non-Goals:**
- Fine-grained per-file ACLs — RedoxFS doesn't support POSIX ACLs
- PAM-style pluggable auth — upstream userutils uses redox_users directly
- Enforcing the generated `etc/security/namespaces` and `etc/security/policy` files — no consumer exists for those yet; they remain informational
- Upstreaming changes to userutils — we work with the login/sudo/su as-is
- Container (`contain`) integration — separate concern, separate change
- Multi-seat / display isolation — the `display*` scheme glob already handles this

## Decisions

1. **Per-user `schemes` option in users.nix** — Add an optional `schemes` field to the user type. When set, it produces a `[user_schemes.<name>]` entry in `login_schemes.toml`. When unset, login falls back to `DEFAULT_SCHEMES` in the binary. Root gets all 26 default schemes plus `proc` (for debugging tools). Regular users get a restricted set: no `irq`, `sys`, `memory`, `serio`.

2. **Test via graphical profile variant** — The functional-test profile currently does NOT include userutils (to keep tests simple). Multi-user tests need a separate test profile (or a conditional test script that skips when userutils is absent). We'll add a `multi-user-test.nix` profile that includes userutils and configures two users with different scheme lists.

3. **Test execution model** — Tests can't use interactive terminal login (serial input doesn't support tcsetattr for password prompts). Instead, the test startup script runs as root and uses `contain` or direct `su -c` for non-root execution. The `sudo --daemon` is already running from the service system. We test by: (a) running `id -u` as root to confirm uid 0, (b) using process spawning to run as user 1000, (c) checking scheme visibility with `ls :`, (d) checking file access with write attempts.

4. **Password handling in tests** — Test users get empty passwords (`user;` in shadow). This lets `su` work without interactive password entry (su checks if password is blank and skips prompt). For sudo tests, the test user has blank password so `write(fd, "")` works.

5. **login_schemes.toml generation** — The existing hardcoded root entry in `generated-files.nix` is replaced by dynamic generation from `users.nix` data. Each user with a `schemes` list gets an entry. Format matches what userutils expects: `[user_schemes.<name>]\nschemes = [...]`.

## Risks / Trade-offs

- **Upstream userutils behavior undocumented** — The `login_schemes.toml` format, `DEFAULT_SCHEMES` list, and `mkns` behavior are all reverse-engineered from source. If upstream changes, our config generation could break. Mitigated by pinning userutils source via flake lock.

- **Testing without interactive login** — We can't test the actual `login` flow (it needs a terminal). We test the building blocks: namespace restrictions work, file ownership works, sudo scheme works. The login→mkns→setns path is trusted because it's upstream code with straightforward logic.

- **Empty passwords in test images** — Not a security concern for test VMs, but the test profile must not be used as a base for real deployments. The `requirePasswords` security option exists for that.

- **su without password for blank-password users** — Upstream `su` skips password prompt when the caller is root OR when target user has blank password. Our tests run the initial script as root, so su to non-root user works. Testing su FROM non-root user to root requires root to have a blank password too (or we skip that test path).
