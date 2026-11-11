# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/brittonr/nix-redox/compare/v0.1.1-alpha...HEAD
[0.1.1-alpha]: https://github.com/brittonr/nix-redox/releases/tag/v0.1.1-alpha
[0.1.0-alpha]: https://github.com/brittonr/nix-redox/releases/tag/v0.1.0-alpha
