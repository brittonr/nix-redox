## Context

Generation management (create, switch, rollback, GC, boot selection) is fully implemented for userspace — packages, config files, and profile symlinks. The kernel, initfs, and bootloader are built as Nix derivations on the host and baked into both the ESP (FAT32) and RedoxFS root (`/boot/`) at image build time. They are never touched after that.

The generation manifest (`manifest.json`, schema v1) has no fields for boot component store paths. `activate-boot` rebuilds the package profile and config files but doesn't touch `/boot/` or the ESP. `has_boot_config_changed()` in `activate.rs` already detects driver/initfs changes and sets `reboot_recommended`, but there's nothing to reboot *into* — the kernel/initfs on disk are always the original build.

Key files:
- `nix/redox-system/modules/build/manifest.nix` — manifest schema
- `nix/redox-system/modules/build/default.nix` — assembly (kernel, initfs, ESP, rootfs)
- `nix/redox-system/lib/make-esp-image.nix` — ESP partition builder
- `nix/redox-system/lib/make-redoxfs-image.nix` — RedoxFS partition builder
- `snix-redox/src/system.rs` — Manifest struct, generation management
- `snix-redox/src/activate.rs` — activation logic, `has_boot_config_changed()`
- `snix-redox/src/rebuild.rs` — rebuild, bridge routing, config evaluation

## Goals / Non-Goals

**Goals:**
- Generation manifests track which kernel, initfs, and bootloader were active when the generation was created
- Rolling back to a generation restores that generation's boot components on disk
- Rebuilds that change drivers, init scripts, or boot config trigger kernel/initfs rebuilds on the host and deliver them through the existing bridge/cache pipeline
- Manifest v1 (without boot paths) remains readable — missing boot fields mean "don't touch boot components"

**Non-Goals:**
- Bootloader menu listing generations (like NixOS GRUB entries) — Redox's UEFI bootloader doesn't support this; the single-kernel-on-ESP model is kept
- Bootloader updates via generation switch — the bootloader binary changes rarely and doesn't need per-generation tracking (just track it for completeness)
- A/B ESP partitions or fallback boot schemes — too much complexity for the current stage
- Atomic ESP writes — FAT32 doesn't support atomic rename; we accept the small window of inconsistency during file copy

## Decisions

### 1. Manifest v2 with `boot` section in generation info

Add a `boot` field to the manifest:

```json
{
  "manifestVersion": 2,
  "boot": {
    "kernel": "/nix/store/abc...-kernel/boot/kernel",
    "initfs": "/nix/store/def...-initfs/boot/initfs",
    "bootloader": "/nix/store/ghi...-bootloader/boot/EFI/BOOT/BOOTX64.EFI"
  }
}
```

Store paths point to the actual files within the derivation output. The Nix store on the RedoxFS root partition already contains these derivations (they're inputs to the disk image build). We just need to ensure they're also installed as addressable store paths on the rootfs, not just copied into `/boot/` loosely.

**Why top-level `boot` and not nested under `generation`**: Boot components are a property of the system state, not the generation metadata. The generation section tracks bookkeeping (id, timestamp, description). Boot components are alongside `packages` and `drivers`.

**v1 compatibility**: The `boot` field uses `#[serde(default)]` with `Option` types. Missing = None = don't touch boot components. Existing v1 manifests and generations work unchanged.

### 2. Boot components installed as store paths in rootfs

Currently `make-redoxfs-image.nix` copies `${kernel}/boot/kernel` to `root/boot/kernel` — a loose file, not a store path. Change this to install the full derivation output directories into `/nix/store/` on the rootfs and symlink `/boot/kernel` → `/nix/store/...-kernel/boot/kernel`.

This is the same pattern NixOS uses: the kernel is a store path, generations reference it, GC keeps it alive via roots.

**Alternative considered**: Record just the file hash, not the store path. Rejected because you can't reconstruct the file from a hash — you need the actual bytes on disk to copy back to the ESP.

### 3. Activation writes kernel/initfs to boot locations

`activate_boot()` gains a new step: if the target generation's manifest has `boot` paths and they differ from the current manifest's boot paths, copy the new kernel/initfs to `/boot/kernel`, `/boot/initfs`, and the ESP mount point.

**ESP access**: The ESP is a FAT32 partition. On Redox, it's not mounted by default after boot (the bootloader reads it, then the kernel runs from memory). Two options:
- (a) Mount the ESP during activation and write to it
- (b) Write only to `/boot/` on RedoxFS; the bootloader reads from RedoxFS `/boot/` not the ESP

Looking at the Redox bootloader: it loads kernel and initfs from the ESP (`::EFI/BOOT/kernel`). After boot, the kernel runs from memory. The copies in RedoxFS `/boot/` are there for reference but aren't used at runtime.

**Decision**: Write to RedoxFS `/boot/` always. Mount and write to ESP only if possible (best-effort — activation shouldn't fail if ESP mount fails). Log a "reboot recommended" message when boot components change, same as service changes.

### 4. Bridge rebuild detects boot-affecting changes

`rebuild.rs` already has `has_boot_config_changed()` checking driver lists. Extend this to also detect init script changes and boot configuration changes. When boot changes are detected:

1. The bridge request includes a flag indicating boot components need rebuilding
2. The host-side bridge rebuilds the initfs (and kernel if kernel config changed) as new Nix derivations
3. The new derivations are exported through the binary cache like packages
4. The guest installs them as store paths and updates the manifest's `boot` section

**Config changes that affect boot components**:
- `hardware.storageDrivers`, `hardware.networkDrivers`, `hardware.graphicsDrivers`, `hardware.audioDrivers` → initfs rebuild
- Init script changes (services added/removed) → initfs rebuild
- Kernel is rarely rebuilt (only if kernel package itself changes) — track it but don't rebuild dynamically

### 5. GC root tracking for boot store paths

The generation GC system already creates roots per generation. Add the boot component store paths to the GC root set for each generation. When a generation is deleted, its boot component roots are removed. If no other generation references the same kernel/initfs store path, GC can collect it.

## Risks / Trade-offs

**[ESP write window]** → FAT32 can't do atomic writes. If power is lost mid-copy, the ESP could have a corrupt kernel. Mitigation: write to a temp name first, then rename (FAT32 rename is closer to atomic than overwrite). Also, the RedoxFS `/boot/` copy serves as a fallback reference.

**[Disk space]** → Each distinct initfs build (~8-64MB) lives in the store. With aggressive driver changes across generations, this adds up. Mitigation: GC already handles this — `snix system gc` removes unreferenced store paths.

**[ESP mount reliability]** → If the ESP can't be mounted (missing driver, corrupt FAT32), activation still succeeds for userspace but boot components aren't updated. Mitigation: log a clear warning; the system still boots with whatever's on the ESP.

**[Bridge dependency for boot changes]** → Kernel/initfs rebuilds require the host bridge (cross-compilation). Can't rebuild boot components locally on Redox. Mitigation: this is already the case for package changes — the bridge path is established.
