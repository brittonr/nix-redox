## 1. Manifest Extensions

- [x] 1.1 Add `toplevel` and `etcSource` store path strings to manifest JSON in `manifest.nix`
- [x] 1.2 Add `toplevel: Option<String>` and `etc_source: Option<String>` fields to `Manifest` struct in `system.rs`

## 2. Rust Activate — /etc/static

- [x] 2.1 Add `setup_etc_static()` function to `activate.rs` that creates/updates `/etc/static` symlink to the etc derivation path
- [x] 2.2 Add per-file symlink creation: walk etc derivation, create `/etc/<path> → /etc/static/<path>` for each managed file
- [x] 2.3 Add stale symlink cleanup: remove `/etc/` symlinks that target old `/etc/static/` entries no longer present
- [x] 2.4 Call `setup_etc_static()` from `activate()` after config file updates, gated on `manifest.etc_source.is_some()`

## 3. Rust Activate — /run/current-system

- [x] 3.1 Add `update_current_system_link()` function to `activate.rs` that creates `/run/current-system → $toplevel` and `/nix/var/nix/gcroots/current-system → /run/current-system`
- [x] 3.2 Call `update_current_system_link()` from `activate()` after GC root updates, gated on `manifest.toplevel.is_some()`

## 4. VM Integration Test

- [x] 4.1 Create test script `nix/redox-system/test-scripts/23-activate-toplevel.ion` that runs `snix system switch` and verifies /etc/static, /run/current-system, gcroots, and per-file symlinks
- [x] 4.2 Create test profile `nix/redox-system/profiles/activate-toplevel-test.nix`
- [x] 4.3 Wire the test into `nix/flake-modules/system.nix` as `activate-toplevel-test` package and functional test

## 5. Verification

- [x] 5.1 Run `nix build .#snix` in snix-redox — existing tests pass with new Manifest fields (Option defaults to None)
- [x] 5.2 Build the activate-toplevel-test disk image
- [ ] 5.3 Run the VM functional test and verify all FUNC_TEST assertions pass (requires interactive VM boot)
