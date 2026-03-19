## 1. Module system: per-user scheme lists

- [x] 1.1 Add optional `schemes` field to user type in `users.nix` — accepts a list of strings or the literal `"restricted"`
- [x] 1.2 Define `restrictedSchemes` constant in `build/config.nix` — the 22-scheme set without `irq`, `sys`, `memory`, `serio`
- [x] 1.3 Define `fullSchemes` constant in `build/config.nix` — all 26 DEFAULT_SCHEMES plus `proc`
- [x] 1.4 Replace hardcoded `login_schemes.toml` in `generated-files.nix` with dynamic generation from users module — iterate `inputs.users.users`, emit `[user_schemes.<name>]` for each user with a `schemes` attribute
- [x] 1.5 Resolve `"restricted"` string to the actual restricted scheme list during generation
- [x] 1.6 Default: root gets `fullSchemes`, non-root users with `createHome = true` get `"restricted"` unless overridden
- [x] 1.7 Artifact test: verify `login_schemes.toml` contains both `[user_schemes.root]` and `[user_schemes.user]` sections with correct scheme counts

## 2. Artifact tests for multi-user config

- [x] 2.1 Artifact test: `/etc/passwd` has root (uid 0) and user (uid 1000) entries
- [x] 2.2 Artifact test: `/etc/group` has `sudo` group with `user` as member (existing test rootTree-has-sudo-group)
- [x] 2.3 Artifact test: `/etc/shadow` exists with mode 0600 (mode 444 after Nix store stripping)
- [x] 2.4 Artifact test: `/bin/login`, `/bin/su`, `/bin/sudo`, `/bin/id` exist in root tree when userutils is in systemPackages
- [x] 2.5 Artifact test: `login_schemes.toml` is valid TOML (parse check via explicit scheme override test)

## 3. Multi-user test profile

- [x] 3.1 Create `multi-user-test.nix` profile — includes userutils, configures root (full schemes) and user (restricted schemes), both with empty passwords, user in sudo group
- [x] 3.2 Wire profile into flake as `run-redox-multi-user-test` app and `multi-user-test` check
- [x] 3.3 Verify profile boots to completion with `FUNC_TESTS_COMPLETE`

## 4. VM test script: identity and file ownership

- [x] 4.1 Create `05-multi-user.ion` test script (renamed from 22 to run before e2e-rebuild FUNC_TESTS_COMPLETE)
- [x] 4.2 Test `root-uid`: run `id -u` as root, expect `0`
- [x] 4.3 Test `root-whoami`: run `id -un` as root, expect `root`
- [x] 4.4 Test `user-home-write`: as root, write to `/home/user/test_write` — verify succeeds
- [ ] 4.5 Test `user-root-denied`: as uid 1000, attempt to write to `/root/test_write` — expect permission error (BLOCKED: upstream `su` has no `-c` flag, needs interactive shell)
- [ ] 4.6 Test `user-uid`: as uid 1000, run `id -u` — expect `1000` (BLOCKED: same — no non-interactive su)
- [ ] 4.7 Test `user-whoami`: as uid 1000, run `id -un` — expect `user` (BLOCKED: same)

## 5. VM test script: privilege escalation

- [x] 5.1 Test `sudod-running`: verify sudod scheme daemon is running (check `ls :` includes `sudo`)
- [ ] 5.2 Test `sudo-id`: as uid 1000 (in sudo group), run `sudo id -u` — expect `0` (BLOCKED: needs non-root context)
- [ ] 5.3 Test `su-to-root`: as uid 1000, run `su` — expect root shell (BLOCKED: su lacks -c flag)
- [ ] 5.4 Test `su-back`: after su to root, shell exits, confirm original uid restored (BLOCKED: same)

## 6. VM test script: namespace config validation

- [x] 6.1 Test `login-schemes-root`: login_schemes.toml has `[user_schemes.root]` entry
- [x] 6.2 Test `login-schemes-restricted`: user's scheme list does NOT include `irq`, `sys`, `memory`, `serio` (verified via grep -c count = 1)
- [x] 6.3 Test `login-schemes-user`: login_schemes.toml has `[user_schemes.user]` entry
- [x] 6.4 Tests `login-schemes-root-proc`, `has-irq`, `has-sys`, `user-no-irq`, `user-no-serio`, `both-file`, `both-pty` — all pass via /etc/test-login-schemes.sh

## 7. Integration and cleanup

- [x] 7.1 Run full multi-user test suite in VM — 19/19 multi-user tests pass (1 skip: sudod without userutils)
- [x] 7.2 Run existing functional-test suite — no regressions, multi-user tests run and pass (165/188 pass, 8 pre-existing failures)
- [x] 7.3 Run artifact tests — all 7 new artifact tests pass
- [x] 7.4 Update AGENTS.md with multi-user / namespace testing notes if needed
