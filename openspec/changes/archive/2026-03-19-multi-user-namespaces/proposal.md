## Why

Everything runs as root. The module system generates passwd, shadow, groups, login_schemes.toml, and security policy files — but nothing reads them at runtime. The userutils `login` binary should create per-user namespaces with restricted scheme access, `su`/`sudo` should escalate through the sudo scheme daemon, and non-root users should be unable to touch root-owned files or kernel schemes. None of this is tested. We have the pieces (userutils, sudod, contain, namespace config) but they're disconnected.

Redox's security model is namespaces-as-capabilities: if a scheme isn't in your namespace, you can't open it. This is already how the kernel works. We just need to wire it up through the login path and prove it works.

## What Changes

- **Per-user namespace enforcement**: `login` creates a child namespace containing only the schemes listed in `login_schemes.toml` for that user. Validate this actually happens — non-root users shouldn't see `proc:`, `irq:`, `sys:` (unless explicitly granted).
- **Sudo scheme validation**: Prove `su` and `sudo` work through the sudod scheme daemon. User can escalate to root, run a command, drop back. Password verification via shadow file.
- **File ownership enforcement**: Home directories are owned by their user (redoxfs-ar sets uid/gid). Verify user can write to their home, cannot write to root's home or `/etc/`.
- **Per-user scheme lists in module system**: The `security.namespaceAccess` options and `login_schemes.toml` should be configurable per-user, not just a root override. Wire the users module into login_schemes generation so each declared user gets their own scheme list.
- **VM test suite for multi-user**: A new test script that boots with userutils, logs in as non-root user, and validates isolation. Tests run through the existing functional-test harness.

## Capabilities

### New Capabilities
- `user-namespace-isolation`: Per-user scheme namespace enforcement via login — non-root users get restricted scheme access, validated at runtime
- `sudo-scheme-escalation`: Privilege escalation through the sudod scheme daemon — su/sudo work, password verification, uid switching
- `multi-user-vm-tests`: VM-based test suite proving user isolation, file ownership, scheme restrictions, and privilege escalation

### Modified Capabilities
- `namespace-sandboxing`: Extend to cover per-user namespace configuration (currently only covers build sandbox)

## Impact

- `nix/redox-system/modules/users.nix` — per-user scheme lists
- `nix/redox-system/modules/security.nix` — wire namespace config to login_schemes.toml
- `nix/redox-system/modules/build/generated-files.nix` — per-user login_schemes.toml generation
- `nix/redox-system/modules/build/config.nix` — plumb new user options
- `nix/redox-system/test-scripts/` — new multi-user test script
- `nix/redox-system/profiles/` — test profile with userutils + multi-user config
- Depends on upstream userutils login reading `login_schemes.toml` (need to verify)
