# Autoresearch: iteration speed of testing and image build

## Objective
Speed up the normal host-side edit -> build -> boot -> smoke-test loop for Redox VM work.

Full `functional-test` is red on the current tree, so benchmark now uses a dedicated smoke image and runner:
1. build `.#functionalSmokeTest` and `.#redox-functional-smoke-test`
2. run the built `functional-test` binary from that smoke package
3. let the smoke suite complete normally

The smoke image contains only scripts `01-shell.ion` through `04-env.ion` plus the minimal package set they need. This keeps the benchmark green and makes image-build work visible without depending on later broken scripts.

## Metrics
- **Primary**: `total_ms` (ms, lower is better) — end-to-end wall time for build plus smoke-test run
- **Secondary**:
  - `build_ms` — time to realize runner + disk image outputs
  - `run_ms` — time to boot VM and finish functional tests
  - `image_bytes` — built disk-image size

## How to Run
`./autoresearch.sh` — builds the dedicated smoke package/image, runs the smoke suite to completion, and prints structured `METRIC ...` lines.

## Files in Scope
- `nix/pkgs/infrastructure/mk-vm-test.nix` — host-side VM test runner setup, disk copy, polling, cleanup
- `nix/pkgs/infrastructure/functional-test.nix` — functional-test wrapper composition
- `nix/flake-modules/system.nix` — wrapper packaging around functional-test variants
- `nix/redox-system/profiles/functional-smoke-test.nix` — dedicated small smoke-test image/profile
- `nix/redox-system/lib/make-redoxfs-image.nix` — RedoxFS partition assembly
- `nix/redox-system/lib/make-disk-image.nix` — final raw disk image assembly
- `nix/redox-system/modules/build/default.nix` — image-builder wiring if needed for safe fast paths
- `autoresearch.sh` / `autoresearch.md` / `autoresearch.ideas.md` — harness and notes

## Off Limits
- Guest test semantics in `nix/redox-system/test-scripts/`
- Benchmark cheating: no skipping boot, no skipping tests, no fake success markers
- Unrelated package graph churn outside test/image iteration path

## Constraints
- Functional-test workload must still boot and pass normally.
- No benchmark-only shortcuts that a real `nix build` / `nix run .#functional-test` user would not get.
- Prefer changes that help more than one profile when safe.
- Do not overfit to one host by relying on filesystem features that are absent elsewhere unless code has a safe fallback.

## What's Been Tried
- Full-suite baseline was a bad benchmark choice here: current tree times out/fails after early scripts, so it cannot separate performance regressions from ordinary red tests.
- Cached smoke benchmark was green, but build_ms was mostly Nix eval/cache overhead and varied by about a second between unchanged reruns.
- Forcing `nix build --rebuild` used to be blocked here because `redox-disk-image-unstable` randomized GPT GUIDs. The current kept tree patches GPT disk/partition GUIDs and CRCs in place after `parted`, so `nix build .#redox-functional-smoke-test --rebuild --no-link` now succeeds again.
- Current benchmark pivot: dedicated `functional-smoke-test` profile so the smoke suite completes normally and the image excludes unrelated packages/tests.
- Kept wins so far:
  - host-side `--stop-after-script` keyed off existing `--- *.ion ---` serial banners
  - dedicated smoke profile and smoke-only runner
  - smoke image down to `diskSizeMB = 608`, `espSizeMB = 64`
  - `make-redoxfs-image.nix` uses `fallocate` fallback and targeted writable dirs instead of `chmod -R`
  - smoke runner disables unused QEMU backend; CH-only closure dropped sharply
  - removed unused `redox-liner-src` input
  - moved `tokei` source from top-level flake input to package-local fetcher
  - canonicalized the actual smoke-path GitLab metadata: `nix/pkgs/userspace/ion-build-plan.json` now uses `.git` for `liner`/`calc`/`small`, and relibc now canonicalizes `andypython/object.git` in both cargo source mapping and source metadata
  - `packages.nix` now exports `legacyPackages.redoxEnv`, and `system.nix` reuses it instead of importing `redox-env.nix` again; this removed a duplicate flake-env/nixpkgs instantiation from the smoke path
  - smoke profile now excludes `rtcd`, `ptyd`, and `ipcd` from the initfs daemon set; broader daemon trimming still broke boot, but dropping those three daemons gave steady smoke wins while still booting and passing normally
- Initial likely hotspots from code read:
  - `mk-vm-test.nix` copies the full raw disk image into a temp dir before every VM boot.
  - `make-redoxfs-image.nix` zero-filled the whole RedoxFS image with `dd` before the fallocate fast path landed.
  - `make-disk-image.nix` assembles final raw disk with two `dd` writes after GPT partitioning.
  - current `functional-test --filter` only filters host-side reporting; it does not shorten guest execution.
- Class results after resume:
  - top-level input pruning is real, but selective: `redox-liner-src` and `tokei-src` helped; `shellharden-src`, `exampled-src`, and post-warning `object-src` pruning did not.
  - smaller-than-`608/64` smoke images reduced bytes but stopped helping total_ms.
  - harness toggles lost: direct two-target `nix build` and runner CLI metadata hooks were both slower than the current single-target + `nix path-info` harness.
  - the legacy `nix/pkgs/default.nix` ion package path is NOT the active smoke path; canonicalizing URLs there did nothing. The real warning source was `nix/pkgs/userspace/ion-build-plan.json` plus relibc source metadata.
  - duplicate `redox-env.nix` evaluation across `packages.nix` and `system.nix` was a real dirty-build hotspot; reusing `legacyPackages.redoxEnv` brought the current observed best down to about `5598ms` total / `4622ms` build.
  - routing smoke-path core packages through extra `legacyPackages` indirection did NOT help after the shared-env fix.
  - `pkgs.extend` versus `import nixpkgs { overlays = ...; }` inside `redox-env.nix` was effectively a wash after the shared-env fix.
  - small smoke-profile cleanup like `hardware.networkDrivers = [ ]` beats a same-file dirty control but still does not beat the current tree.
  - Cloud Hypervisor qcow2 overlays with a backing file are blocked on this host: the current CH build errors with `CreateQcowDiskSync(BackingFilesDisabled)`.
  - `base.src` passthru lookup is cheap (`nix eval --raw .#base.src.drvPath` ~`260ms`), so the remaining `basePerCrate` hotspot is mostly unit2nix/workspace aggregation, not patched-source lookup.
  - smoke-only monolithic `base` is invalidated as an optimization path: while it was a huge no-op benchmark win (~`4490ms` steady-state), the same base-touch trigger that gave the current per-crate tree `12483ms` made the monolithic smoke path explode to `27277ms`, confirming it hides real base-edit iteration cost.
  - a more principled smoke-only `baseSmokePerCrate` that prunes the base build plan to smoke-needed members still lost (`6546ms` steady-state), so simple caller-side member pruning is not enough; the next likely win is deeper inside unit2nix's graph construction.
  - in-repo vendoring of `build-from-unit-graph.nix` is a bad benchmark path here: even a no-op local copy of the current upstream file regressed badly (~`9011ms` steady-state), so future unit2nix experiments must update the real input cleanly or work entirely on Redox-side hotspots.
  - benchmarking against the real local `../unit2nix` input path requires its own control: overriding Redox to current local `unit2nix` HEAD already lands around `6621ms`, slower than the locked input. A real-input host/member-closure pruning patch still lost (`6833ms` steady-state), so that upstream candidate is not worth pursuing as implemented.
  - more image-build micro-tuning has now lost badly: larger-block final `dd` writes in `make-disk-image.nix` regressed to `12062ms`, and writing ESP/RedoxFS/final images directly into `$out` regressed even harder to `14641ms`.
  - runner micro-tuning has also lost: making the smoke disk read-only to skip the image copy crashed during early boot (`Request check failed ... ReadOnly`), and incremental serial-log polling in `mk-vm-test.nix` was flat/worse than a same-file control.
  - Redox-side `mkCrossPackage` member hints are too weak on current unit2nix: passing `members = [ member ]` was effectively noise against a same-file control, so if member filtering matters it needs a stronger upstream implementation.
  - `redox-disk-image-unstable` nondeterminism root cause was GPT disk/partition GUID randomness from `parted`. Repeated local reproductions differed only near the primary and backup GPT headers. A full `sgdisk` rewrite proved the diagnosis by making `nix build .#redox-functional-smoke-test --rebuild --no-link` succeed, but it regressed the smoke benchmark badly (`8739ms` steady-state against a `7438ms` same-file control).
  - current kept fix avoids the `sgdisk` regression: `make-disk-image.nix` still uses fast `parted`, then normalizes GPT disk/partition GUIDs plus CRCs in place. Same-file dirty benchmarking favored that patch over both the old random-`parted` path and the slower full-`sgdisk` rewrite, and rebuild determinism is restored on current HEAD.
  - another plausible image tweak also lost: removing kernel/initfs payload copies from the ESP still let the smoke VM boot, but the first measured run regressed badly (`13006ms`), so ESP payload slimming is not an obvious speed win here.
  - important confound correction: switching `system.nix` to `bootloaderPerCrate` was a false keep for this session's metric. The smoke runner is Cloud-Hypervisor-only (`defaultMode = "ch"`, `enableQemu = false`), and `mk-vm-test.nix` only consumes the `bootloader` arg on the QEMU path, so that change was not causally on the active benchmark path and has been reverted.
  - the deeper on-path `bootloaderPerCrate` experiment is also blocked for now: after generating the missing `nix/pkgs/system/bootloader-build-plan.json`, the per-crate UEFI build still failed in `aes` with undefined `__extendhfsf2` / `__truncsfhf2`, so treat `bootloaderPerCrate` as incomplete rather than a ready optimization lever.
  - narrower smoke-profile initfs trimming is still viable: excluding `rtcd` kept the smoke workload green and improved a same-file comparison; a direct hot-cache A/B then showed excluding `ptyd` improved total_ms further; a second direct hot-cache A/B showed excluding `ipcd` on top of `rtcd+ptyd` improved total_ms further again; and later direct hot-cache revalidation around `acpid` showed the `rtcd+ptyd+ipcd+acpid` profile beat the immediate no-`acpid` control (`9877ms` and `10253ms` vs `12336ms`), despite one much noisier earlier validation rerun (`13872ms`). `hwd` remains unsafe to exclude, and the broader `acpid`/`hwd`/`rtcd` trim broke boot during switchroot.
  - narrowing smoke-profile hardware to the actual Cloud Hypervisor workload was another real win: setting `storageDrivers = [ "virtio-blkd" ]` and `networkDrivers = [ ]` on top of the daemon trims brought the hot-cache run down to about `7190-7241ms`.
  - excluding `lived` on top of the `rtcd+ptyd+ipcd+acpid` and virtio-only trims was another real hot-cache win: follow-up runs landed around `7022-7257ms`, and a later warm rerun reached `6873ms`.
  - smoke-profile Cloud Hypervisor resource cuts now look stale: `1024MiB/1 vCPU` and `512MiB/1 vCPU` both lost badly, and `512MiB/2 vCPU` was confounded by repeated broad rebuilds rather than showing a credible win.
  - matching the `acpid` initfs trim at the `/power.acpiEnable = false` config layer did NOT help; the second pass still lost (~`8063ms`) against the current virtio-only profile.
  - retrying smaller smoke images after the newer daemon+driver trims still did not beat the current `608MiB` profile: `576MiB` landed around `7380ms`, and `592MiB` landed around `8391ms`.
  - smaller ESP experiments also look stale now: `32MiB` was too small (`mkfs.fat ... Disk full`), and `48MiB` regressed badly on build_ms while leaving run_ms flat.
  - more initfs-service surgery is a bad path here: replacing `hwd` with a direct `pcid` override while excluding `hwd` caused catastrophic rebuild-heavy regressions, even though the guest still booted.
  - `make-redoxfs-image.nix` rootTree copy micro-tune `cp -a --reflink=auto` was also a clear loser on this host; even the follow-up run stayed dramatically slower.
  - `make-disk-image.nix` install-phase `cp disk.img` → `mv disk.img` was effectively flat against a same-file dirty control (~`12429ms` vs `12515ms`), so not worth keeping.
  - smoke-only `diskImageBootCompat = false` (skip copied `$out/boot/*` compatibility files while keeping `redox.img`) did NOT help; it still lost badly (~`8401ms`) against the lived-trimmed current head (~`6873ms`).
  - `boot.initSkip = [ "hwd" ]` is NOT a safe substitute for excluding `hwd`; the image built but boot failed during switchroot with the same `redoxfs ... file 0000000000000000 failed with exit status: 1` shape as broader unsafe daemon trims.
  - `mk-vm-test.nix` runtime disk staging with `cp --sparse=always` also lost slightly against a same-file dirty control (~`7602ms` vs `7465ms`), so sparse host-side copies are stale on this profile.
  - current local `unit2nix` HEAD is only slightly slower than the locked input when benchmarked from a clean detached worktree (`7210-7216ms` warm via `UNIT2NIX_INPUT=git+file:///tmp/...`), so do not update blindly but also do not over-interpret the earlier slower path-specific `7999ms` run.
  - a local `unit2nix` experiment to disable `test`/`clippy` outputs by default was much worse (~`14000ms` warm), so that upstream lever is stale as implemented.
  - a different local `unit2nix` patch looks mildly promising: delaying test/clippy graph construction until the `.test`/`.clippy` outputs are actually accessed improved a clean override-input run from about `7210-7216ms` to about `7036-7182ms`. That is still low-confidence, but it is the first upstream-style unit2nix tweak in a while that did not outright lose.
  - a post-warm-up current-head rerun on the lived-trimmed virtio-only profile now reached `6873ms` (`build_ms=6014`, `run_ms=858`), which is the best observed warm run so far on this branch.
  - do NOT prefetch dependencies inside the primary timed metric just to make numbers look better. That would hide real edit-loop cost. If cold-fetch noise ever becomes worth studying, spin a separate session/metric for cold-vs-hot behavior instead of mutating this benchmark.
