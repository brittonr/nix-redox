## Why

The upstream Redox OS rebase (27 flake inputs updated, Feb→Mar 2026) is 95% complete but three components still fail to build: bootstrap (stale Cargo.lock), redox-rt (API change), and virtio-fsd (API change). These block the tier-cross check and prevent producing a bootable disk image from the updated sources.

## What Changes

- Regenerate bootstrap Cargo.lock for new relibc deps (goblin 0.7→0.10), working around Nix FOD store-path reference check
- Update virtio-fsd source for upstream redox-scheme 0.11 API changes (SchemeState removal, method signature changes)
- Fix redox-rt per-crate build for upstream relibc refactoring
- Regenerate bootloader build plan for new bootloader-src target structure

## Capabilities

### New Capabilities
- `bootstrap-lockfile-regen`: Mechanism to regenerate bootstrap Cargo.lock when relibc deps change, avoiding Nix FOD reference check
- `upstream-api-compat`: Source-level fixes for virtio-fsd and redox-rt to match upstream redox-scheme 0.11 and relibc API changes

### Modified Capabilities

## Impact

- `nix/pkgs/infrastructure/bootstrap.nix` — lockfile generation strategy
- `nix/pkgs/system/virtio-fsd/` — scheme handler code for redox-scheme 0.11
- `nix/pkgs/system/base-build-plan.json` — may need per-crate override for redox-rt
- `nix/pkgs/system/bootloader-build-plan.json` — regeneration for new target structure
- tier-cross check gate — currently failing, blocks tier-vm
