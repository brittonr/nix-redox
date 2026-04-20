# Vendored crate / forked source inventory

Live inventory for `sync-vendored-crates-upstream`.

Scope rule: count only explicit local divergence markers in `nix/pkgs/`, `snix-redox/`, and source-bundle derivations:
- forked crate or package source pins
- vendored dependency patching after vendor creation
- local workspace copies of upstream crates
- source-bundle-only patch or metadata carry

Do **not** count ordinary offline vendoring (`fetchCargoVendor`, crane vendoring, unit2nix auto-vendoring) when the source remains ordinary upstream with no Redox-local divergence.

## Validation classes

- **host-only** — host build/test path enough
- **guest-facing** — affects Redox-native package/runtime behavior; needs focused VM/package coverage in addition to host build where applicable
- **dual-use** — used by both packaged host builds and guest/source-bundle/self-hosting flows; needs host validation plus guest/self-hosting coverage

## Current explicit carry sites

| ID | Owner / site | File path(s) | Local carry type | Carried crate/source | Current upstream candidate | Blast radius | Required validation path | Disposition | Reason / blocker | Retry trigger | Dependent package paths |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | `pkgutils` ring replacement | `flake.nix`, `nix/pkgs/userspace/pkgutils.nix` | Forked crate source replacing vendored crates.io crate | `ring` from `redox-os/ring` branch `redox-0.17.8` | Upstream `ring` release/tarball that ships usable pregenerated assembly for Redox, or upstream build flow that no longer needs the `.git` / pregenerated workaround | guest-facing | host cross-build of `pkgutils` + guest package smoke (`pkg` start/install path) | keep-local | crates.io tarball still lacks pregenerated asm inputs needed by Redox build; local replacement remains structural | upstream `ring` release or packaging change that makes Redox build from upstream tarball work without post-vendor replacement | `nix/pkgs/userspace/pkgutils.nix` |
| C2 | shared `cc-rs` fork | `flake.nix`, `nix/pkgs/system/relibc.nix`, `nix/pkgs/userspace/extrautils.nix`, `nix/pkgs/userspace/pkgutils.nix` | Forked crate source / git pin | `cc` from `tea/cc-rs` branch `riscv-abi-arch-fix` | latest upstream `rust-lang/cc-rs` / crates.io `cc` release containing needed ABI fixes | dual-use | host cross-builds for touched packages; if sync lands in `relibc`, also focused guest coverage for a C-dependent package and/or self-hosting path that uses `cc` | update | likely stale fork, but blast radius is shared and not independent; treat as later shared batch, not first isolated batch | confirm upstream `cc` release includes needed fix and package trio still builds with no branch pin | `nix/pkgs/system/relibc.nix`, `nix/pkgs/userspace/extrautils.nix`, `nix/pkgs/userspace/pkgutils.nix` |
| C3 | shared `rustix` Redox ioctl fork | `flake.nix`, `nix/pkgs/system/base.nix`, `nix/pkgs/userspace/orbital.nix` | Forked crate source / git branch | `rustix` from `jackpot51/rustix` branch `redox-ioctl` | upstream `rustix` once Redox ioctl support lands | guest-facing | host cross-build + focused guest runtime coverage for touched package (`base` boot / `orbital` graphical boot) | keep-local | Redox ioctl support still carried in fork; high runtime risk | upstream `rustix` release with equivalent Redox ioctl API/behavior | `nix/pkgs/system/base.nix`, `nix/pkgs/userspace/orbital.nix` |
| C4 | base vendored ACPI patch | `nix/pkgs/system/base.nix`, `nix/pkgs/patches/patch-acpi-match-opcode.py` | Patched vendored dependency after vendor creation | vendored `acpi` crate Match opcode implementation | upstream `jackpot51/acpi` / released `acpi` crate with AML Match opcode support | guest-facing | host cross-build of `base` + focused boot/initfs coverage on ACPI path | keep-local | missing Match opcode support still patched in vendor tree; boot/runtime relevant | upstream `acpi` merge/release with Match opcode support, then rerun boot proof | `nix/pkgs/system/base.nix` |
| C5 | extrautils `filetime` fork | `flake.nix`, `nix/pkgs/userspace/extrautils.nix` | Forked crate source rewritten to path dep | `filetime` from `jackpot51/filetime` | upstream `filetime` `0.2.27` from crates.io | guest-facing | host cross-build of `extrautils`; guest smoke for a binary that still exercises the updated build path | update | host cross-build is green via `nix build .#packages.x86_64-linux.extrautils`, and guest smoke is green via `nix build .#packages.x86_64-linux.activate-toplevel-test` (profile includes `extrautils`; script uses guest `grep`) | regressions in guest `grep`/`extrautils` usage or future upstream `filetime` release changes behavior | `nix/pkgs/userspace/extrautils.nix` |
| C6 | bottom forked package source | `flake.nix`, `flake.lock`, `nix/pkgs/userspace/bottom.nix` | Forked package source + forked transitive git dep | `bottom` from `jackpot51/bottom` plus `sysinfo` from `jackpot51/sysinfo` | upstream `ClementTsang/bottom` `0.11.2` plus crates.io `sysinfo 0.37.0` with narrow Redox-local patches in package prep | guest-facing | host cross-build of `bottom` + focused guest launch smoke | update | host cross-build is green via `nix build .#packages.x86_64-linux.bottom`; focused guest smoke is also green via an ad hoc tty image built with `pkgs.mkRedoxSystem` + `userutils`, where `/nix/system/profile/bin/btm --version` succeeds and `/nix/system/profile/bin/btm --basic` starts on a real Redox tty and exits cleanly on `q` | regressions in the local Redox patch set or future upstream `bottom`/`sysinfo` changes | `flake.nix`, `flake.lock`, `nix/pkgs/userspace/bottom.nix` |
| C7 | orbital compat carry | `flake.nix`, `nix/pkgs/userspace/orbital.nix` | Local workspace copy + path rewrites + version rewrites | pinned `base` subdirs (`inputd`, `graphics-ipc`, `daemon`) from `base@620b4bd`, plus patched dependency graph | newer upstream `orbital` + `base` combination that no longer needs compat snapshot/path surgery | guest-facing | host cross-build + graphical VM boot | defer | package is guest-critical but not low-risk: carries pinned compat snapshot, version rewrites, and runtime mmap fixups together | upstream `orbital`/`base` dependency alignment on modern syscall/drm stack | `nix/pkgs/userspace/orbital.nix` |
| C8 | rustc vendored jobserver patch | `nix/pkgs/userspace/rustc-redox.nix`, `nix/pkgs/userspace/patches/patch-jobserver-poll.patch` | Patched vendored dependency inside upstream Rust vendor tree | vendored `jobserver` crate in Rust source tarball | upstream Rust toolchain release whose vendored `jobserver` no longer needs Redox poll workaround | guest-facing | toolchain build + focused guest/self-hosting compile using patched cargo/rustc path | defer | patch targets Redox `poll()` behavior inside self-hosting-critical toolchain; not good first slice | upstream Rust/nightly vendor picks up equivalent fix, or Redox `poll()` gap disappears | `nix/pkgs/userspace/rustc-redox.nix` |
| C9 | `snix-redox` upstream workspace carry | `nix/pkgs/infrastructure/snix-upstream-source.nix`, `nix/pkgs/infrastructure/snix-source-bundle.nix`, `nix/pkgs/userspace/snix.nix`, `snix-redox/Cargo.toml`, `snix-redox/regenerate-build-plan.sh` | Local upstream workspace copy + shared-source patching + source-bundle metadata carry | copied upstream `snix` workspace crates under `upstream/`, Redox sed/patch carry, pregenerated proto descriptors, no-CA fetcher patch | newer upstream `snix` commit/release that absorbs individual Redox carries | dual-use | host validation via `./scripts/validate-snix-redox-host.sh`, packaged `snix` build, `nix build .#snix-source-bundle`, then focused `.#snix-compile-test` / `.#snix-sandbox-test` and self-hosting coverage as needed | defer | biggest dual-use batch; many local carries; must refresh upstream-source derivation, bundle metadata, and build plans together | upstream absorbs one or more patches, or a targeted isolated sub-carry proves removable with full host + guest validation | `nix/pkgs/infrastructure/snix-upstream-source.nix`, `nix/pkgs/infrastructure/snix-source-bundle.nix`, `nix/pkgs/userspace/snix.nix`, `snix-redox/` |
| C10 | legacy ion `nix` pin | `nix/pkgs/default.nix` | Forked crate source / git pin in legacy package path | `nix` from `nix-rust/nix` rev `ff6f8b8a` | upstream `nix` crate release used directly from crates.io or current upstream git | guest-facing (legacy package path) | host cross-build of legacy `ion` package path before trusting removal | defer | explicit carry exists, but ownership/activeness of `nix/pkgs/default.nix` path should be settled first; not first batch | confirm legacy package set still matters, then retest against upstream `nix` crate | `nix/pkgs/default.nix` `userspace.ion` |
| C11 | legacy uutils vendored `ctrlc` patch | `nix/pkgs/default.nix` | Patched vendored dependency after vendor creation | vendored `ctrlc` crate rewritten to Redox no-op implementation | upstream `ctrlc` release with acceptable Redox behavior, or package removal from legacy path | guest-facing (legacy package path) | host cross-build of legacy `uutils` path + focused runtime signal smoke if still used | keep-local | explicit Redox-only vendor rewrite still present, but package path appears legacy and should not block active-path sync work | upstream `ctrlc` Redox semantics become usable, or legacy package path retired | `nix/pkgs/default.nix` `userspace.uutils` |

## Initial implementation order

### First low-risk independent batch

These are the first `update` candidates because they are independent non-`snix-redox` sites:

1. **C5 — `extrautils` / `filetime`**
   - isolated package-local carry
   - no shared source-bundle coupling
   - host cross-build and focused guest smoke are now both green
2. **C6 — `bottom` / `sysinfo`**
   - isolated package-local fork
   - guest-facing, but narrower than `base`, `orbital`, or toolchain paths

### Later shared / higher-risk batches

- **C2 — `cc-rs`**: likely updatable, but shared across `relibc`, `extrautils`, and `pkgutils`; do after the first isolated package syncs
- **C9 — `snix-redox`**: reserve for explicit later batch with upstream-source refresh, `snix-redox/regenerate-build-plan.sh`, source-bundle rebuild, offline build check, and guest/self-hosting validation
- **C3 / C4 / C7 / C8**: keep-local or defer until upstream/runtime conditions change

## Shared-source / offline-build notes

- `snix` no-CA fetcher patch is shared between packaged-build and source-bundle flows; if it survives any sync attempt, keep explicit idempotency / prior-application detection.
- Any `snix-redox` graph change must refresh the upstream-source derivation first, then rerun `snix-redox/regenerate-build-plan.sh`, then rebuild source-bundle metadata.
- After every successful source sync, verify offline vendoring still works through the normal Nix package or source-bundle path; do not accept cargo-only green results.
- For source bundles using `fetchCargoVendor`, verify `.cargo/config.toml` still points at `vendor/source-registry-0` and `vendor/source-git-0` where applicable.

## Ordinary vendoring currently not counted as sync targets

These paths use vendoring for offline builds but do not currently show an additional Redox-local crate-source carry beyond normal packaging:

- `nix/pkgs/infrastructure/ripgrep-source-bundle.nix`
- `nix/pkgs/infrastructure/native-kernel-rebuild-bundle.nix`
- `nix/pkgs/infrastructure/bootstrap.nix`
- `nix/pkgs/infrastructure/initfs-tools.nix`
- `nix/pkgs/userspace/mk-userspace.nix` consumers that only use upstream source + vendor hash with no extra crate replacement or vendor patching

Re-evaluate these only if a sync attempt uncovers a hidden fork, vendored patch, or source-bundle-specific divergence.
