## ADDED Requirements

### Requirement: Manifest records boot component store paths
The system manifest SHALL include a `boot` section containing Nix store paths for the kernel, initfs, and bootloader that were active when the generation was created.

#### Scenario: Fresh build includes boot paths in manifest
- **WHEN** a disk image is built from a configuration profile
- **THEN** `/etc/redox-system/manifest.json` has `manifestVersion` of 2
- **AND** `boot.kernel` contains a `/nix/store/...-kernel/boot/kernel` path
- **AND** `boot.initfs` contains a `/nix/store/...-initfs/boot/initfs` path
- **AND** `boot.bootloader` contains a `/nix/store/...-bootloader/boot/EFI/BOOT/BOOTX64.EFI` path

#### Scenario: Boot paths reference files that exist on the rootfs
- **WHEN** the system boots from a v2 manifest
- **THEN** the file at the `boot.kernel` store path exists and is readable
- **AND** the file at the `boot.initfs` store path exists and is readable

### Requirement: Boot components installed as store paths on rootfs
The build system SHALL install kernel, initfs, and bootloader derivation outputs into `/nix/store/` on the root partition, not only as loose files in `/boot/`.

#### Scenario: Store paths present alongside /boot copies
- **WHEN** a disk image is built
- **THEN** the kernel derivation output exists under `/nix/store/` on the RedoxFS partition
- **AND** `/boot/kernel` exists (for bootloader compatibility)
- **AND** both contain identical bytes

### Requirement: v1 manifests remain readable
The manifest parser SHALL accept manifests without the `boot` section (v1 format) by treating missing boot fields as None.

#### Scenario: Load v1 manifest without boot section
- **WHEN** a manifest with `manifestVersion: 1` and no `boot` field is loaded
- **THEN** parsing succeeds
- **AND** `boot.kernel` is None
- **AND** `boot.initfs` is None

#### Scenario: Generation switch from v1 to v2 manifest
- **WHEN** the current active manifest is v1 (no boot paths)
- **AND** a switch to a v2 manifest (with boot paths) is performed
- **THEN** the switch succeeds
- **AND** boot components are updated on disk from the v2 manifest's paths

### Requirement: Generation snapshots preserve boot paths
When a generation is saved, the generation's manifest snapshot SHALL include the boot component store paths from the active manifest.

#### Scenario: Rebuild preserves boot paths in new generation
- **WHEN** `snix system rebuild` creates generation 2
- **AND** the kernel/initfs did not change
- **THEN** generation 2's manifest has the same `boot.kernel` and `boot.initfs` as generation 1

#### Scenario: Rebuild with new initfs records updated path
- **WHEN** `snix system rebuild` creates generation 3 with a new initfs
- **THEN** generation 3's `boot.initfs` differs from generation 2's `boot.initfs`
- **AND** both store paths exist on the rootfs

### Requirement: GC roots include boot component store paths
The generation GC system SHALL create GC roots for boot component store paths alongside package store paths.

#### Scenario: Boot store paths protected from GC while generation exists
- **WHEN** generation 2 references `/nix/store/abc-kernel` and `/nix/store/def-initfs`
- **AND** `snix system gc` is run
- **THEN** `/nix/store/abc-kernel` and `/nix/store/def-initfs` are NOT collected

#### Scenario: Boot store paths collected after generation deletion
- **WHEN** generation 2 is the only generation referencing `/nix/store/old-initfs`
- **AND** generation 2 is deleted via `snix system delete-generations 2`
- **AND** `snix system gc` is run
- **THEN** `/nix/store/old-initfs` is eligible for collection
