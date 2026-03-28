## 1. Bootstrap Cargo.lock Regeneration

- [ ] 1.1 Generate bootstrap Cargo.lock offline: copy patched bootstrap+initfs source to /tmp, run `cargo generate-lockfile`, copy the resulting Cargo.lock to `nix/pkgs/infrastructure/bootstrap-Cargo.lock`
- [ ] 1.2 Update bootstrap.nix patchedSrc to copy the checked-in lockfile over the stale upstream one in installPhase
- [ ] 1.3 Update bootstrap vendor hash (set dummy, get real hash from error, set correct hash)
- [ ] 1.4 Verify `nix build .#packages.x86_64-linux.bootstrap` succeeds
- [ ] 1.5 Add comment in bootstrap.nix documenting the lockfile regen procedure

## 2. virtio-fsd API Update

- [ ] 2.1 Read the redox-scheme 0.11 source to identify the replacement for SchemeState and changed method signatures
- [ ] 2.2 Update `nix/pkgs/system/virtio-fsd/src/scheme.rs` to use the new redox-scheme 0.11 API
- [ ] 2.3 Verify virtio-fsd compiles as part of `nix build .#packages.x86_64-linux.basePerCrate`

## 3. redox-rt Per-Crate Build Fix

- [ ] 3.1 Check the redox-rt compile error details (may need to build on remote builder and fetch log)
- [ ] 3.2 Add extraCrateOverrides for redox-rt in the base workspace buildFromUnitGraph call, or fix the source path resolution
- [ ] 3.3 Verify redox-rt builds within the base per-crate build

## 4. Verification

- [ ] 4.1 Run `nix build .#checks.x86_64-linux.tier-cross --no-link` and confirm it passes
- [ ] 4.2 Run `nix build .#checks.x86_64-linux.tier-eval --no-link` to confirm no regressions
- [ ] 4.3 Run `nix build .#checks.x86_64-linux.tier-host --no-link` to confirm no regressions
- [ ] 4.4 Commit all changes with descriptive message
