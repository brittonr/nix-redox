# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Reproducible asciinema demo (`demo/record-e2e.py`): serial-console UEFI boot,
  login, `tree --version`, `snix eval`, a fresh `snix build`, and
  `snix system info`/`snix system services`, rendered to MP4 and published on
  the site.
- Self-build evidence video and reproducible renderer
  (`demo/render-self-build.py`), generated from the `native-rebuild-test`
  capture: seed build, native boot, rollback, 134/134 pass.
- Flake-free builds with [Nixtamal](https://nixtamal.toast.al/):
  `default.nix` and `shell.nix` evaluate the flake's outputs from the pins in
  `nix/tamal` (one per `flake.lock` node) and produce the same derivations as
  the flake. The `nixtamal-pins` eval check and a CI step keep the two in
  sync; see `docs/nixtamal.md`.
- Native upstream Nixtamal 3.1.0 in Redox development images, with a
  cross-built OCaml runtime and C bindings. Snix provides native archive/Git
  prefetch, hash conversion, loader evaluation, and genuine store/GC-root
  operations. An isolated `nixtamal-test` VM exercises lock, refresh, pinned
  revisions, generated loaders, and retained input generations offline; see
  `docs/nixtamal.md`.
- Static browser-local x86_64 Redox images and immutable Nix site outputs,
  with a real serial terminal, offline Snix install/build/rollback fixtures,
  explicit lifecycle/reset behavior and measured browser resource policies.
- A separate direct Snix-WASM playground and real Orbital framebuffer/input
  profile, plus matched native-to-browser snapshot capture and resume bindings.

### Changed

- Redesigned the landing page (`site/`): numbered sections for running, the
  demo, the self-build proof, the build pipeline, configuration, image contents,
  status and docs; light and dark themes that follow the OS, with a toggle;
  self-hosted Archivo and JetBrains Mono fonts; copy buttons; keyboard-operable
  tabs; and asciinema players that load as they scroll into view. Without
  JavaScript every panel stays visible and the recordings play as MP4s.
- `shell.nix` and `default.nix` no longer require the `flakes` experimental
  feature or copy the whole working tree into the store; `nix-build` builds the
  default disk image.

### Fixed

- Redox source inputs use shallow Git transport instead of the GitLab archive
  API, which returns HTTP 403 on hosted CI. Locked revisions, NAR hashes and
  source timestamps are unchanged.

- Removed obsolete artifact assertions for startup-unit command spelling and
  write bits on immutable Nix-store files. Real boot and declared home-file
  content checks remain.

- QEMU runners separate backend selection from `auto`/`kvm`/`tcg` acceleration;
  forced TCG uses `qemu64` and a fresh serial-command nonce rather than a boot
  banner as shell evidence. Startup reconnects to the serial console instead
  of reading EOF from the logger, and Ion `read` checks raw-mode capability
  while retaining its input binding across conditional scopes.
- Automatic boot selection is independent of live filesystem loading, with
  explicit disk/live and manual/automatic bootloader variants and fail-closed
  patch-drift checks. Non-live boot no longer implies a filesystem-sized RAM copy.
- Browser machine contracts use the pinned WASM backend's initialized MTTCG
  loop with one vCPU and a representable 1024 MiB allocation. Runtime startup
  distinguishes Emscripten's successful live-runtime return from actual exits,
  flushes early failure serial output, and preserves phase-entry timestamps.
- Handwritten TCG/libffi bridges and chunk completion mailboxes use unsigned
  wasm32 heap addresses; JavaScript/Wasm imports agree on fixed 3 GiB memory.
  Nonblocking PTY reads preserve partial input and EAGAIN without waiting for
  another keystroke; guest RAM remains independently configured.
- Browser serial checks use the terminal's actual native Ctrl+Shift+V paste
  event and verify typed input, CRLF multiline paste, and guest Ctrl+C byte
  delivery rather than treating Ctrl+V's literal-next byte as a paste.
- The 64-bit HPET clock source uses its free-running counter, so coalesced
  emulation interrupts do not slow the guest clock.
  External sleep checks separate executable startup with a warmed sleep control.
  A 16-second default interval amortizes command/scheduling jitter without
  widening the 35% tolerance, and raw/control/adjusted timings are retained before
  asserting. The real four-times-fast-clock self-test uses a baseline-length
  sleep rather than an interval small enough for executable/serial overhead
  to mask.
- Snapshot artifact admission accepts safe nested firmware-pack paths and QEMU
  ROM filenames while rejecting traversal and URL escapes.
- Browser failure probes let the session's readiness timeout precede the outer
  harness bound, remove protected guest tools without prompts, and reject
  incompatible snapshot identities even when their artifact hashes are valid.
- Browser disk probes use available guest filesystem tools and buffered writes
  instead of absent utility applets, without lowering cache or overlay quotas.
- Rejected lazy root-disk writes promptly fail and dispose the owning VM and
  reject pending commands, instead of waiting for a guest-command timeout.
  The real 64 MiB quota gate verifies ENOSPC, bounded failure delivery and a
  fresh reset that discards partial writes and executes a new guest nonce.
- Binary-cache exports include complete target-aware runtime closures and
  truthful References; guest restoration traverses and verifies dependencies
  even when a root is already present.
- Browser pages no longer freeze during long guest serial transfers. Engine
  finalization makes the pinned Emscripten runtime signal a synchronous proxy
  waiter before unlocking its stack-allocated context; previously the page's
  main thread could signal reused stack memory and spin indefinitely. The cache
  gate also uses a measured bound for bundled package installs and reports an
  unreleased receiver immediately instead of waiting on a disabled control.
  Stop checks wait up to 10 s for Chromium to terminate the removed document's
  engine workers (about 2 s measured) rather than sampling once after 1 s.
- Native Git preserves URI transports before probing Redox-local scheme paths,
  so cloning a `file://` repository no longer prefixes the working directory
  onto its protocol.
- Git helper command strings use the guest's POSIX Bash while cross-build
  generators continue to use the host shell. Runtime assembly retains
  `libexec/`, templates, Unicode data, and notices needed by Git and Nixtamal.
- Native Git fetching resolves pinned ancestors from advertised history on
  servers that reject direct requests for unadvertised commit IDs.

## [0.1.2-alpha] - 2026-11-11

### Added

- Data-only per-user home files (`users.<name>.files`), aligned with the
  adios-native configuration model rather than Home Manager activation.
- Cross-compiled `tree` package, included in the development profile and the
  cross check tier.
- `snix system services` read-only listing, with `--json` output, verified in a
  guest against the declared service manifest.

## [0.1.1-alpha] - 2026-11-11

### Added

- Verified NixOS integration: documented `programs.redox`/`services.redox-vm`,
  and added an eval-tier check for module defaults and opt-in cache settings.
- Generated module options reference at `docs/options.md` and the `redox-help`
  search command, with a drift check in the eval tier.
- `redox-rebuild switch` and `boot` aliases plus `--dry-run` planning for host-side
  builds, and user-facing documentation for generations and rollback.
- Gated Cachix workflow (`.github/workflows/cache.yml`) and binary-cache setup,
  trust, and usage documentation.
- `redox-rebuild image` and `export`, including SHA-256 output for raw disk images.
- Installation documentation covering VM, verified USB writing, and guest updates.
- `redox-install`, a checksum-validating image writer with mounted/undersized
  device checks, explicit confirmation, dry-run, and read-back verification.
- Package porting guide covering Rust plans, C cross-builds, vendoring, and CI.
- Static marketing landing page and GitHub Pages deployment workflow.
- Troubleshooting guide for dead host substituters/build farms, direnv fallback,
  and expected headless boot warnings.
- Public `nix-redox` Cachix cache wired into the flake, docs, and CI; CI
  publishes minimal/graphical images for Nix 2.24.9 and 2.35.1 (store paths are
  Nix-version dependent). Verified cold-store substitution in 89 seconds plus
  local final-image assembly.
- Tag release workflow that builds graphical/minimal images, writes checksums,
  and uploads them to the GitHub release.

### Changed

- The NixOS integration module no longer injects a private cache or public key;
  `programs.redox.binaryCacheUrl` and `binaryCachePublicKey` are opt-in.
- `push-cache` and `cache-status` now require an explicit cache URL instead of
  defaulting to a private host.

## [0.1.0-alpha] - 2026-11-11

### Added

- Complete Redox OS images assembled from source with Nix: UEFI bootloader,
  kernel, initfs, base daemons, userspace, and Orbital graphics.
- Graphical and headless runners, disk-image builds, and a Nix registry alias
  workflow.
- Declarative, composable system modules and image profiles.
- Guest-side `snix` system management: rebuild, generations, rollback, garbage
  collection, and package installation.
- Build bridge for pushing host-built packages into a running VM.
- Self-hosting image with native rustc, cargo, LLVM/LLD, and `snix build`.
- Native system and kernel rebuild bundles with boot-selection proofs.
- Tiered validation apps from fast evaluation checks through VM integration
  suites, plus focused network, bridge, sandbox, and self-hosting tests.

### Fixed

- Kernel ptrace tracing now completes cleanly for traced processes, including
  exit notification and end-of-trace reads; `strace` runs end to end.
- Network configuration discovers the Redox `eth0` interface without relying on
  unsupported scheme directory listings.
- Guest-native builds and system activation preserve environment, environment
  variables, and rollback metadata across generations.

[Unreleased]: https://github.com/brittonr/nix-redox/compare/v0.1.2-alpha...HEAD
[0.1.2-alpha]: https://github.com/brittonr/nix-redox/releases/tag/v0.1.2-alpha
[0.1.1-alpha]: https://github.com/brittonr/nix-redox/releases/tag/v0.1.1-alpha
[0.1.0-alpha]: https://github.com/brittonr/nix-redox/releases/tag/v0.1.0-alpha
