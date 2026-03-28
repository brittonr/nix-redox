## 1. Bootstrap Cargo.lock Regeneration

- [x] 1.1 Generate bootstrap Cargo.lock offline: copy patched bootstrap+initfs source to /tmp, run `cargo generate-lockfile`, copy the resulting Cargo.lock to `nix/pkgs/infrastructure/bootstrap-Cargo.lock`
- [x] 1.2 Update bootstrap.nix patchedSrc to copy the checked-in lockfile over the stale upstream one in installPhase
- [x] 1.3 Update bootstrap vendor hash (set dummy, get real hash from error, set correct hash)
- [x] 1.4 Verify `nix build .#packages.x86_64-linux.bootstrap` succeeds
- [x] 1.5 Add comment in bootstrap.nix documenting the lockfile regen procedure

## 2. virtio-fsd API Update

- [x] 2.1 Read the redox-scheme 0.11 source to identify the replacement for SchemeState and changed method signatures
- [x] 2.2 Update `nix/pkgs/system/virtio-fsd/src/scheme.rs` to use the new redox-scheme 0.11 API
- [x] 2.3 Verify virtio-fsd compiles as part of `nix build .#packages.x86_64-linux.basePerCrate`

## 3. redox-rt Per-Crate Build Fix

- [x] 3.1 Check the redox-rt compile error details (may need to build on remote builder and fetch log)
- [x] 3.2 Regenerate userutils-build-plan.json via unit2nix with new relibc-src deps (redox_protocols, goblin 0.10, redox_syscall 0.7.3); fix stale vendorHash for pkgutils and redoxfs-target; patch userutils sudo.rs import for relocated ProcCall type
- [x] 3.3 Verify redox-rt builds within the base per-crate build

## 4. Verification

- [x] 4.1 Run `nix build .#checks.x86_64-linux.tier-cross --no-link` and confirm it passes
- [x] 4.2 Run `nix build .#checks.x86_64-linux.tier-eval --no-link` to confirm no regressions
- [x] 4.3 Run `nix build .#checks.x86_64-linux.tier-host --no-link` to confirm no regressions
- [x] 4.4 Commit all changes with descriptive message
