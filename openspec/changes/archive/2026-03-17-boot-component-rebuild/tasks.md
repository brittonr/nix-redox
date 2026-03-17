## 1. Extend RebuildConfig with services field

- [x] 1.1 Add `services: Option<Vec<String>>` to `RebuildConfig` in `rebuild.rs` — list of declared service names from configuration.nix
- [x] 1.2 Update `has_boot_affecting_changes()` to accept the current manifest and compare declared services when `config.services` is `Some` — return true on any name difference vs `manifest.services.declared` keys

## 2. Boot path diffing in print_changes

- [x] 2.1 Add boot path comparison to `print_changes()` — when both current and merged have `boot: Some(...)`, show lines for kernel/initfs/bootloader path differences
- [x] 2.2 Update `auto_rebuild()` reason message to include "service changes detected" when services differ

## 3. Unit tests for boot-affecting detection

- [x] 3.1 Test: each hardware field alone (storage, network, graphics, audio, usb) triggers `has_boot_affecting_changes()` — 5 test cases
- [x] 3.2 Test: empty hardware block (`Some` with all `None` fields) does NOT trigger detection
- [x] 3.3 Test: services field with added service triggers detection (compare against sample manifest)
- [x] 3.4 Test: services field with removed service triggers detection
- [x] 3.5 Test: services field matching current manifest does NOT trigger detection
- [x] 3.6 Test: no services field (None) does NOT trigger detection for services

## 4. Unit tests for boot path diffing

- [x] 4.1 Test: `print_changes()` output includes boot path diff when initfs changes
- [x] 4.2 Test: `print_changes()` output has no boot lines when boot paths are identical
- [x] 4.3 Test: `print_changes()` handles `boot: None` on either side without panic

## 5. Verify and clean up

- [x] 5.1 Run full test suite (`cargo test` in snix-redox) — all existing + new tests pass
- [x] 5.2 Verify `needs_bridge()` still correctly combines package, hardware, and service checks
