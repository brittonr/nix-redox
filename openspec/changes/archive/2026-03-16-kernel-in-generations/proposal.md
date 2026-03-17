## Why

Generation rollback currently only covers userspace — packages and config files. The kernel, initfs, and bootloader are baked into the disk image at build time and stay fixed across all generation switches. If a rebuild pulls in a new driver set or init script change that breaks boot, there's no way to roll back the boot components. NixOS handles this by storing kernel/initrd per generation and letting the bootloader select them.

## What Changes

- Generation manifests gain `boot.kernel`, `boot.initfs`, and `boot.bootloader` fields recording the Nix store paths of the boot components that were active when the generation was created
- `snix system activate-boot` copies the selected generation's kernel/initfs to the ESP before handing off to the bootloader, so generation rollback includes boot components
- `snix system rebuild` (bridge path) can request kernel/initfs rebuilds from the host when `configuration.nix` changes affect drivers, init scripts, or boot config — the new boot components are pushed through the binary cache alongside packages
- The build system writes kernel/initfs into the Nix store on the root partition (not just the ESP) so they survive as addressable store paths for generation tracking

## Capabilities

### New Capabilities
- `boot-component-tracking`: Generation manifests record kernel/initfs/bootloader store paths; activation restores the correct boot components for the selected generation
- `boot-component-rebuild`: Bridge rebuild detects boot-affecting config changes (drivers, init scripts, boot settings) and rebuilds kernel/initfs on the host, exporting them through the binary cache

### Modified Capabilities
- `boot-generation-select`: Activation now copies kernel/initfs to ESP in addition to swapping packages and config
- `guest-rebuild`: Rebuild detects boot-component changes and routes them through bridge alongside package changes

## Impact

- **Manifest schema**: `manifestVersion` bumps to 2 (new `boot` section); existing v1 manifests remain readable (missing boot fields = "untracked, don't touch ESP")
- **snix-redox**: `activate.rs` gains ESP write logic; `rebuild.rs` gains boot-change detection
- **Build modules**: `build/default.nix` and `make-esp-image.nix` install kernel/initfs as store paths on rootfs in addition to ESP
- **Bridge protocol**: New request type for kernel/initfs export (same mechanism as package export)
- **Disk space**: Kernel (~2MB) + initfs (~8-64MB depending on drivers) stored in Nix store per distinct build; GC already handles store path cleanup
