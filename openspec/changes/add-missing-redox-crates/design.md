## Context

Our nix-redox build integrates 22 of 45 crates listed in the Redox OS book. 7 of the 23 missing are dead (ralloc replaced by dlmalloc, orbtk deprecated). The remaining 8 are live crates needed for bare metal support, debugging, package distribution, and the wider ecosystem. We want full ecosystem coverage, not just VM demos.

Current build patterns:
- **Host tools** (run on Linux): built natively, placed in `nix/pkgs/host/`
- **Cross-compiled Rust binaries**: use `mkUserspace.mkPackage` or `mkCrossPackage` (unit2nix)
- **Cross-compiled Rust libraries**: go into the sysroot or are deps of other packages
- Flake inputs point to GitLab sources; vendoring uses `fetchCargoVendor` or unit2nix

The ring crate is the biggest obstacle — it needs pregenerated assembly files from the Redox OS git fork (`redox-os/ring.git` branch `redox-0.17.8`), not the crates.io tarball.

## Goals / Non-Goals

**Goals:**
- Build all 8 missing crates that have maintained upstream sources
- Fix pkgutils (already has .nix file, just blocked on ring crate)
- Add pkgar-repo as a workspace member of the existing pkgar build
- Add host tools (redoxer, kprofiling) as native Linux packages
- Add cross-compiled libraries (gdb-protocol, buffer-pool, intelflash) to the sysroot or as standalone packages
- Each crate builds independently — no cascading rebuilds

**Non-Goals:**
- Building slint_orbclient — can't confirm this exists as a standalone buildable crate on GitLab; defer until confirmed
- Building crates confirmed dead upstream (ralloc, orbtk, redox_event_update, orbclient_window_shortcuts, reagent, gitrepoman, redox_liner, redox_uefi_std)
- Modifying any existing package builds
- Adding anything to the default disk image (these go into profiles or binary cache)

## Decisions

### 1. Ring crate: vendor from git, not crates.io

pkgutils and pkgar-repo both pull in `reqwest → rustls → ring`. The crates.io ring tarball lacks pregenerated assembly files needed for Redox. The Redox fork at `redox-os/ring.git` branch `redox-0.17.8` has them.

**Approach**: Add `ring-redox-src` as a flake input pointing to the Redox fork. In the vendor phase, replace the crates.io ring with the git source and regenerate `.cargo-checksum.json`. This is the same pattern we use for other git-dependent crates (orbclient, rustix, drm-rs in base).

**Alternative considered**: Patch ring's build.rs to skip assembly generation. Rejected — the pregenerated files are the upstream-supported approach and the fork is maintained by the Redox team.

### 2. pkgar-repo: build from existing pkgar workspace

pkgar-repo lives in the pkgar monorepo (`pkgar/pkgar-repo/`). We already have `pkgar-src` as a flake input and build the `pkgar` binary. Adding pkgar-repo means building a second workspace member from the same source.

**Approach**: Extend the existing pkgar.nix or create a separate pkgar-repo.nix that reuses `pkgar-src`. Build with `--manifest-path pkgar-repo/Cargo.toml`. pkgar-repo also depends on reqwest/rustls/ring, so it shares the ring fix with pkgutils.

### 3. Host tools vs cross-compiled: match the crate's purpose

| Crate | Target | Rationale |
|-------|--------|-----------|
| pkgutils | Redox | Runs on Redox to manage packages |
| gdb-protocol | Redox | Library linked into Redox programs/stubs |
| redox_intelflash | Redox | Lib for parsing Intel UEFI images on Redox |
| redox-buffer-pool | Redox | Driver/client shared buffer management |
| redox-kprofiling | Host (Linux) | Converts kernel profiling data to perf script format |
| pkgar-repo | Host (Linux) | Serves package repositories from Linux |
| redoxer | Host (Linux) | Runs Redox programs in KVM from Linux |

### 4. Library crates: build as standalone packages, not sysroot additions

gdb-protocol, redox-buffer-pool, and redox_intelflash are library crates. Rather than injecting them into the sysroot (which would require rebuilding all downstream), build them as standalone Nix packages. Consumers can add them as build inputs when needed.

### 5. Seven crates instead of eight

Dropping slint_orbclient. The crate name appears in the Redox book but there's no confirmed standalone repository or crates.io entry. The Slint framework has its own Redox backend work that's in-progress upstream. We'll add it when there's something concrete to build.

### 6. Module system wiring: extraPkgs + profiles

Cross-compiled Redox packages must flow through two integration points:

1. **`extraPkgs` in `nix/flake-modules/system.nix`** — Maps `self'.packages.X` into the `pkgs` attrset that the module system sees. Without this, `opt "X"` in profiles resolves to `[]` because `pkgs.X` doesn't exist. Every cross-compiled package (pkgutils, gdb-protocol, intelflash, buffer-pool) needs an entry here.

2. **Profiles** — `opt "name"` checks `pkgs ? name` and includes the package in `systemPackages` if present. pkgutils goes in the development profile (already has `opt "pkgutils"`). Library crates (gdb-protocol, intelflash, buffer-pool) are available via `opt` but not added to any default profile — consumers add them when needed.

Host tools (redoxer, pkgar-repo, kprofiling) skip both — they run on Linux and are exposed directly as flake packages (`nix run .#redoxer`).

## Risks / Trade-offs

**[Ring crate version drift]** → The Redox fork pins ring 0.17.8. If upstream pkgutils/pkgar-repo update to a newer ring, the fork may lag. Mitigation: pin the fork rev in the flake input; bump explicitly.

**[redoxer depends on our own packages]** → redoxer 0.2.62 depends on redox_installer, redoxfs, redox_syscall, and redox-pkg (pkgutils lib). These are already in our build as host tools or cross-compiled packages. Mitigation: wire existing packages as build inputs.

**[pkgar-repo reqwest on Redox]** → pkgar-repo uses reqwest with blocking + rustls-tls. If someone tries to cross-compile it for Redox (not our intent), TLS handshake would need working DNS + TCP. Not a risk for host builds.

**[kprofiling kernel integration]** → redox-kprofiling is a converter, not a kernel module. The kernel must be built with profiling support separately for the tool to have data to convert. This change doesn't add kernel profiling support — just the post-processing tool.
