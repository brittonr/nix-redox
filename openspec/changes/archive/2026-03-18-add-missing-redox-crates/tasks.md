## 1. Ring crate foundation (shared by pkgutils + pkgar-repo)

- [x] 1.1 Add `ring-redox-src` flake input pointing to `gitlab:redox-os/ring/redox-0.17.8?host=gitlab.redox-os.org`
- [x] 1.2 Run `nix flake lock --update-input ring-redox-src` to verify the input resolves

## 2. Fix pkgutils (cross-compiled for Redox)

- [x] 2.1 Update `nix/pkgs/userspace/pkgutils.nix` to vendor ring from `ring-redox-src` git source instead of crates.io (replace ring in vendor-combined, regenerate checksum)
- [x] 2.2 Update vendorHash if needed after ring source change
- [x] 2.3 Uncomment pkgutils in `nix/flake-modules/packages.nix` (currently disabled with comment about ring)
- [x] 2.4 Add `pkgutils = self'.packages.pkgutils or null;` to the `extraPkgs` attrset in `nix/flake-modules/system.nix`
- [x] 2.5 Confirm pkgutils is already in development profile (`opt "pkgutils"` in `nix/redox-system/profiles/development.nix`)
- [x] 2.6 Verify `nix build .#pkgutils` produces `bin/pkg` for x86_64-unknown-redox

## 3. Add pkgar-repo (host tool, shares ring fix)

- [x] 3.1 Create `nix/pkgs/host/pkgar-repo.nix` — build from existing `pkgar-src` with `--manifest-path pkgar-repo/Cargo.toml`, native host build, vendor ring from git same as pkgutils
- [x] 3.2 Add pkgar-repo to `nix/flake-modules/packages.nix`
- [x] 3.3 Verify `nix build .#pkgar-repo` produces a native Linux binary

## 4. Add gdb-protocol (cross-compiled lib for Redox)

- [x] 4.1 Add `gdb-protocol-src` flake input pointing to `gitlab:redox-os/gdb-protocol/master?host=gitlab.redox-os.org`
- [x] 4.2 Create `nix/pkgs/userspace/gdb-protocol.nix` — cross-compile with mkUserspace, only dep is memchr
- [x] 4.3 Add gdb-protocol to `nix/flake-modules/packages.nix`
- [x] 4.4 Add `gdb-protocol = self'.packages.gdb-protocol or null;` to `extraPkgs` in `nix/flake-modules/system.nix`
- [x] 4.5 Verify `nix build .#gdb-protocol` produces a Redox library

## 5. Add redox_intelflash (cross-compiled lib for Redox)

- [x] 5.1 Add `intelflash-src` flake input pointing to `gitlab:redox-os/intelflash/master?host=gitlab.redox-os.org`
- [x] 5.2 Create `nix/pkgs/userspace/intelflash.nix` — cross-compile with mkUserspace, deps: bitflags, plain, redox_uefi
- [x] 5.3 Add redox-intelflash to `nix/flake-modules/packages.nix`
- [x] 5.4 Add `redox-intelflash = self'.packages.redox-intelflash or null;` to `extraPkgs` in `nix/flake-modules/system.nix`
- [x] 5.5 Verify `nix build .#redox-intelflash` produces a Redox library

## 6. Add redox-buffer-pool (cross-compiled lib for Redox)

- [x] 6.1 Add `buffer-pool-src` flake input pointing to `gitlab:redox-os/redox-buffer-pool/master?host=gitlab.redox-os.org`
- [x] 6.2 Create `nix/pkgs/userspace/buffer-pool.nix` — cross-compile with mkUserspace, features: `redox` (enables redox_syscall), deps: guard-trait, log
- [x] 6.3 Add redox-buffer-pool to `nix/flake-modules/packages.nix`
- [x] 6.4 Add `redox-buffer-pool = self'.packages.redox-buffer-pool or null;` to `extraPkgs` in `nix/flake-modules/system.nix`
- [x] 6.5 Verify `nix build .#redox-buffer-pool` produces a Redox library

## 7. Add redox-kprofiling (host tool)

- [x] 7.1 Add `kprofiling-src` flake input pointing to `gitlab:redox-os/kprofiling/master?host=gitlab.redox-os.org`
- [x] 7.2 Create `nix/pkgs/host/kprofiling.nix` — native host build, only dep is anyhow
- [x] 7.3 Add redox-kprofiling to `nix/flake-modules/packages.nix`
- [x] 7.4 Verify `nix build .#redox-kprofiling` produces a native Linux binary

## 8. Add redoxer (host tool)

- [x] 8.1 Add `redoxer-src` flake input pointing to `gitlab:redox-os/redoxer/master?host=gitlab.redox-os.org`
- [x] 8.2 Create `nix/pkgs/host/redoxer.nix` — native host build, deps include redox_installer, redoxfs, redox_syscall, redox-pkg, tempfile, proc-mounts, toml
- [x] 8.3 Add redoxer to `nix/flake-modules/packages.nix`
- [x] 8.4 Verify `nix build .#redoxer` produces `bin/redoxer` as a native Linux binary

## 9. Profile and module integration

- [x] 9.1 Add a `development-baremetal` profile (or extend development) that includes `opt "pkgutils"` plus `opt "gdb-protocol"` and `opt "redox-intelflash"` and `opt "redox-buffer-pool"` for bare metal development
- [x] 9.2 Ensure host tools (redoxer, pkgar-repo, kprofiling) are available via `nix run .#redoxer`, `nix run .#pkgar-repo`, `nix run .#redox-kprofiling` (no module integration needed — they run on Linux, not inside Redox)

## 10. Integration verification

- [x] 10.1 Verify all 7 new packages build: `nix build .#pkgutils .#pkgar-repo .#gdb-protocol .#redox-intelflash .#redox-buffer-pool .#redox-kprofiling .#redoxer`
- [x] 10.2 Verify development profile disk image builds with pkgutils enabled
- [x] 10.3 Boot development profile VM and confirm `pkg --help` works
- [x] 10.4 Verify cross-compiled library crates are usable as build inputs (include in a downstream crate's deps)
