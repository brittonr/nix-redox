## 1. activate-boot subcommand

- [ ] 1.1 Add `activate-boot` subcommand to snix-redox CLI that loads a generation's manifest and calls `activate()` without creating a new generation entry
- [ ] 1.2 Add `snix system boot [N]` subcommand that writes/reads `/boot/default-generation` without changing the live system
- [ ] 1.3 Unit tests for activate-boot: valid generation, missing generation, corrupt manifest

## 2. Update switch/rollback to write boot default

- [ ] 2.1 Modify `system::switch()` to write `/boot/default-generation` with the new generation ID after successful activation
- [ ] 2.2 Modify `system::rollback()` to write `/boot/default-generation` after successful rollback
- [ ] 2.3 Verify existing rebuild-generations-test still passes (43/43)

## 3. Init script for boot-time generation activation

- [ ] 3.1 Add `85_generation_select` init script in `init-scripts.nix` that runs `/bin/snix system activate-boot` with the generation from `/boot/default-generation`
- [ ] 3.2 Handle fallback: if snix exits non-zero, log warning to serial and continue boot with current manifest
- [ ] 3.3 Handle missing marker: if `/boot/default-generation` doesn't exist, skip activation entirely

## 4. Integration test

- [ ] 4.1 Create `boot-generation-select-test` profile: boots, rebuilds with hostname change, writes a different generation as boot default, then verifies `activate-boot` produces correct live state
- [ ] 4.2 Create test runner (Cloud Hypervisor, serial log parsing, FUNC_TEST protocol)
- [ ] 4.3 Wire test into flake apps and run to green
