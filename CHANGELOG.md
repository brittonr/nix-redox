# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Guest-built Snix installs as a system package. `snix system rebuild
  --source` builds the package with the seed compiler, switches the
  generation, and the self-hosting test replaces `/bin/snix` with the
  installed binary and verifies `--version` and `eval`. A focused
  `snix-install-test` covers the `$out`-literal package source, `$out`
  builder argument, stale-profile rejection, generation switch, and guest
  binary. Self-hosting test: 89/89 pass.

- Native recipes resolve their builder tools from the seed's store paths.
  `stage0-tools.nix` maps the seed manifest to bash, uutils, rustc, LLVM,
  lld-wrapper, make and the sysroot; the kernel, bootloader, initfs-tools,
  Snix, ripgrep, cc-dependency and workspace recipes consume those paths
  instead of `/nix/system/profile`, so changing a seed tool changes the
  derivation hash.

- Snix evaluates flake inputs as flakes. Every lock node reachable from the
  root is wired recursively with `self`, `sourceInfo`, `inputs`, `outputs`,
  `_type`, and lock `rev`/`shortRev`/`lastModified`/`narHash` metadata;
  `follows` paths resolve from the root, and `flake = false` inputs remain
  plain source trees. The guest flake fixture now covers a nested flake input
  with a `follows` edge.

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
- A multiline guest-command editor with populate-only examples, actual process
  output and exit status, and exclusive serial ownership shared by guided
  actions, package transfer and the playground's explicit guest execution.

### Changed

- The guest Snix build generates its protobuf Rust modules from the bundled
  descriptor sets with `prost` and `tonic-build`. The host-generated
  `generated-protos` sources and the bundle copy step are gone; guest builds no
  longer need `protoc`.

- The guest Snix self-build no longer forces one Cargo job, one codegen unit,
  `panic=abort`, no debuginfo or the serial curve25519 backend. It builds with
  Cargo's defaults at four jobs; `self-hosting-test` passes 87/87 with the
  resulting 455-crate build and source rebuild.

- The guest Snix self-build compiles every proc-macro crate from the real
  vendored sources instead of local shims. Full guest builds of the real
  `serde_derive`, `prost-derive`, `thiserror-impl` and the remaining derive
  crates produce a working `snix` (`--version` and `eval --expr "1 + 1"`).
  The unused `clap_derive`, `pin-project-internal`, `tokio-macros` and
  `serde_with_macros` patch entries are gone.

- The guest bundle no longer patches redb to bypass Serde for a default
  configuration. A 2508-second self-build produced a working `snix` with the
  real derive crates and the default redb configuration.

- Redesigned the landing page (`site/`): numbered sections for running, the
  demo, the self-build proof, the build pipeline, configuration, image contents,
  status and docs; light and dark themes that follow the OS, with a toggle;
  local Helvetica-class and monospace type; copy buttons; keyboard-operable
  tabs; and asciinema players that load as they scroll into view. Without
  JavaScript every panel stays visible and the recordings play as MP4s.
- Landing and live browser surfaces share a Kiln-derived identity: neutral
  paper/ink, local typography, square frames and semantic status signals;
  adapted styling retains the MIT notice. The live lab is one sidebar-free
  workbench: session controls and status, the serial console beside tabbed
  Shell/Nix/Packages/WASM tools, a docked latest-result pane, and collapsible
  help, identity and diagnostics, with the landing page's saved theme.
- The overview and live lab now share project navigation, branding, theme and
  mobile-menu behavior. The homepage introduces the live workflow and links to
  individual tools while retaining the native quick-start and recorded walkthrough.
  Boot and browser-launch links use bright Redox orange with high-contrast dark
  text; command actions remain neutral.
- The homepage, live lab, README and browser-demo docs credit
  [TryNix](https://trynix.dev/) by [Farid Zakaria](https://fzakaria.com/), whose
  QEMU-WASM engine, build recipe and native QEMU the live lab adapts, and Kohei
  Tokunaga's [QEMU-WASM](https://github.com/ktock/qemu-wasm), which TryNix builds on.
- The live lab and homepage are easier to read and navigate. The lab drops the
  Startup and Disk dropdowns (Boot always does a verified cold boot), the eyebrow,
  filler labels, idle placeholder lines and its footer, shortens its text, and
  folds its collapsible panels into **Help** and **Diagnostics**. The homepage
  drops the hero fact strip, the closing call to action and the live-lab and
  recording step lists, and merges **Inside** and **Status** into one section.
  Headings and status text use plain sentences instead of slogan fragments, em
  dashes and arrow glyphs.
- The live browser showcase exposes startup/ready/busy states, measured elapsed
  clocks and download bytes, expandable asset details, and a width-fitting
  readable serial terminal. The homepage links directly to the live demo while
  retaining the recording fallback.
- Root filesystems store each boot binary once. RedoxFS has no hard links, so
  package aliases (uutils applets, Snix's `nix*` names) and every `/usr/bin`
  entry were full copies; they are now relative links, and declared special
  links such as `bin/sh` keep precedence. The live demo's compressed disk falls
  from 320 MB to 119 MB.
- The live demo uses a 384 MiB disk with a 64 MiB ESP, so the browser holds
  512 MiB less expanded disk. Its readiness check runs one Snix evaluation
  instead of five, ordinary guest commands arrive as one quoted argument without
  a base64 decoder or second shell, and firmware files download concurrently.
- `shell.nix` and `default.nix` no longer require the `flakes` experimental
  feature or copy the whole working tree into the store; `nix-build` builds the
  default disk image.
- Builds fetch the pinned upstream Snix commit from its GitHub mirror
  (`github.com/anthropics/snix`) instead of `git.snix.dev`, whose outage failed
  CI and browser-preview builds. The fixed-output hash is unchanged, so source
  contents and build outputs are identical.

### Fixed

- `builtins.removeAttrs` forces each key before string coercion, so flake
  wiring that passes thunked input names no longer panics with
  `Thunk::value called on a suspended thunk`.

- Snix refuses to run a builder whose derivation targets another system,
  naming the required and local systems before any builder or dependency starts
  and pointing at `snix build --bridge`. Flake evaluation and local execution
  share one system identifier, so the selected attribute path and the executor
  cannot disagree.

- The default disk image builds again: duplicated alias binaries had exhausted
  its RedoxFS partition (`redoxfs-ar: No space left on device`).

- The WASM tool's **Run in Redox** status keeps the guest exit status visible
  instead of immediately reverting to the generic ready message.

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
- Browser demo shells enter their writable home after switchroot instead of
  retaining init's unreadable initfs working directory. The real-browser gate
  checks relative file creation and directory listing before terminal workloads.
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
