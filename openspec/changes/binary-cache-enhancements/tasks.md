## 1. Standalone serve-cache command

- [x] 1.1 Create `nix/pkgs/infrastructure/serve-cache.nix` — `writeShellScriptBin` wrapping `python3 -m http.server` with `--port` and `--dir` arguments, startup cache verification
- [x] 1.2 Wire `serve-cache` into `nix/pkgs/infrastructure/default.nix` and register as flake app in `nix/flake-modules/apps.nix`
- [x] 1.3 Test `nix run .#serve-cache` starts and serves files

## 2. Add ripgrep to test binary cache

- [x] 2.1 Update `nix/pkgs/infrastructure/test-binary-cache.nix` to include ripgrep alongside mock-hello in the package list
- [x] 2.2 Verify the built cache contains ripgrep narinfo and NAR

## 3. Extend network install test with ripgrep

- [x] 3.1 Add ripgrep install + execution tests to `nix/redox-system/profiles/network-install-test.nix` after the existing mock-hello tests
- [x] 3.2 Run `nix run .#network-install-test` and verify all tests pass (original 8 + new ripgrep tests)

## 4. HTTPS upstream cache test

- [x] 4.1 Find a stable `x86_64-linux` store path on `cache.nixos.org` and record its hash for the test
- [x] 4.2 Create `nix/redox-system/profiles/https-cache-test.nix` — Ion test script that waits for DHCP, then runs `snix path-info` against `https://cache.nixos.org` with graceful skip on no-internet
- [x] 4.3 Create `nix/pkgs/infrastructure/https-cache-test.nix` — test runner (QEMU + serial polling, same pattern as network-install-test)
- [x] 4.4 Wire up in `default.nix`, `system.nix`, `apps.nix`
- [x] 4.5 Run `nix run .#https-cache-test` and verify pass
