## 1. Manifest Schema v2

- [x] 1.1 Add `BootComponents` struct to `system.rs` with optional `kernel`, `initfs`, `bootloader` store path fields
- [x] 1.2 Add `boot` field to `Manifest` struct with `#[serde(default)]` for v1 compatibility
- [x] 1.3 Bump `manifestVersion` to 2 in `manifest.nix` and add `boot.kernel`, `boot.initfs`, `boot.bootloader` store paths
- [x] 1.4 Unit tests: parse v1 manifest (no boot section) succeeds with None fields; parse v2 manifest with boot paths succeeds; roundtrip serialize/deserialize preserves boot paths

## 2. Store Paths on Rootfs

- [x] 2.1 Modify `make-redoxfs-image.nix` to install kernel/initfs/bootloader derivation outputs into `/nix/store/` on the rootfs (copy full derivation dirs, not just the binary files)
- [x] 2.2 Keep `/boot/kernel` and `/boot/initfs` as copies (bootloader compat) alongside the store paths
- [x] 2.3 Artifact test: verify store paths exist on rootfs and match `/boot/` copies

## 3. Activation with Boot Components

- [x] 3.1 Add `update_boot_components()` to `activate.rs` — compares old/new manifest boot paths, copies changed files to `/boot/`
- [x] 3.2 Wire `update_boot_components()` into `activate()` and `activate_boot()` flows
- [x] 3.3 Skip boot update when manifest boot fields are None (v1 compat) or paths match (no-op)
- [x] 3.4 Log warning and continue if boot store path file is missing (GC'd)
- [x] 3.5 Set `reboot_recommended = true` when boot components change
- [x] 3.6 Unit tests: activation with changed boot paths copies files; activation with same paths skips; activation with None boot section skips; activation with missing store path warns

## 4. GC Roots for Boot Components

- [x] 4.1 Extend generation GC root creation to include boot component store paths from the generation's manifest
- [x] 4.2 Unit test: GC roots include boot store paths; deleting generation removes boot roots; shared boot paths across generations keep roots until last generation deleted

## 5. Bridge Boot Rebuild

- [x] 5.1 Extend `has_boot_config_changed()` to cover all boot-affecting fields (all driver lists, usbEnabled, init script changes)
- [x] 5.2 Update `auto_rebuild()` routing to treat boot-affecting changes same as package changes (require bridge)
- [x] 5.3 Add boot component rebuild request to bridge protocol — host evaluates updated config, builds new initfs derivation, exports via cache
- [x] 5.4 Guest side: install boot component NARs from cache, update manifest boot paths, activate
- [x] 5.5 Integration test: config change adding a driver triggers bridge rebuild, new generation has different initfs path, `/boot/initfs` updated

## 6. End-to-End Validation

- [x] 6.1 Integration test: build image → boot → verify v2 manifest with boot paths → rebuild with hostname change → verify boot paths unchanged → rollback → verify original state
- [x] 6.2 Integration test: generation rollback restores previous boot components to `/boot/`
- [x] 6.3 Test v1→v2 migration path: boot with v1 manifest, rebuild creates v2, rollback to v1 generation leaves boot untouched
