# Self-Hosting Plan

## Phase 1: Bridge Rebuild Loop ✅ (completed Mar 2 2026)
- [x] Guest writes RebuildConfig JSON to shared filesystem
- [x] Host daemon picks up request, builds rootTree via bridge-eval.nix
- [x] Host exports binary cache (NAR + narinfo) to shared dir
- [x] Guest polls, installs packages, activates new generation
- [x] Integration test: 11/11 passing (bridge-rebuild-test)

## Phase 2: Expand Toolchain on Redox (current)
- [ ] **Cross-compile cmake for Redox** — closes C build tool gap
- [ ] **Cross-compile Rust compiler (rustc) for Redox** — enables native compilation of ~90% of packages
- [ ] **Cross-compile cargo for Redox** — package manager for native builds

## Phase 3: Native Build Capability
- [ ] **Implement `derivation` builtin in snix-eval** — produce .drv files on guest
- [ ] **Upgrade bridge to derivation-level protocol** — guest sends .drv hashes, host builds missing derivations
- [ ] **Native build support** — snix can invoke local rustc/cargo when available

## Architecture Notes
- Bridge pattern (guest evaluates, host builds) is the near-term path
- Native compilation requires rustc+cargo on Redox (Phase 2)
- snix-eval lacks `derivation` builtin — can't produce .drv files yet (Phase 3)
- tokio/tonic-dependent snix crates NOT portable to Redox — only snix-eval, nix-compat (sync)
