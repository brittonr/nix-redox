# Self-Hosting Plan

## Phase 1: Bridge Rebuild Loop ✅ (completed Mar 2 2026)
- [x] Guest writes RebuildConfig JSON to shared filesystem
- [x] Host daemon picks up request, builds rootTree via bridge-eval.nix
- [x] Host exports binary cache (NAR + narinfo) to shared dir
- [x] Guest polls, installs packages, activates new generation
- [x] Integration test: 11/11 passing (bridge-rebuild-test)

## Phase 2: Expand Toolchain on Redox ✅ (cross-compilation done, runtime blocked)
- [x] Cross-compile cmake 3.31.0 for Redox (19MB static ELF)
- [x] Cross-compile LLVM 21.1.2 (clang 91MB, lld 57MB, llvm-ar 11MB)
- [x] Cross-compile Rust compiler (rustc 284K + 180MB librustc_driver.so)
- [x] Cross-compile cargo (41MB static ELF)
- [x] Self-hosting profile with toolchain, sysroot, CC wrapper, cargo config
- [x] Self-hosting test profile (14/17 tests pass)
- [x] libstdcxx-shim: shared libc++ as libstdc++.so.6 (943 C++ ABI symbols, no libc.so dep)
- [x] randd patch: accept reads from SchemeRoot handles
- [x] **relibc ld_so DSO process state injection** — `rustc -vV` works on Redox!
      Root cause: each .so has private STATIC_PROC_INFO/DYNAMIC_PROC_INFO copies.
      Fix: inject ns_fd/proc_fd from ld_so into DSO statics via get_sym + lazy init.
- [ ] **LLVM flag mismatch**: `-generate-arange-section` removed in LLVM 21.
      Blocks `cargo build` — rustc's target info probe fails.

## Phase 2.5: Fix cargo build (LLVM flag mismatch)
- [ ] Investigate `-generate-arange-section` — where does rustc inject this flag?
- [ ] Patch Rust source or use LLVM version that still supports it
- [ ] Once `cargo build` works: verify hello-world compilation succeeds on-guest

## Phase 3: Native Build Capability
- [ ] **Implement `derivationStrict` in snix-eval** — produce .drv files on guest
- [ ] **Cargo vendoring** — offline crate sources via virtio-fs or disk image
- [ ] **Upgrade bridge to derivation-level protocol** — guest sends .drv hashes, host builds
- [ ] **Native build support** — snix can invoke local rustc/cargo when available

## Architecture Notes
- Bridge pattern (guest evaluates, host builds) is the near-term path
- Native compilation requires fixing ld_so first (Phase 2.5)
- snix-eval lacks `derivationStrict` builtin — can't produce .drv files yet (Phase 3)
- tokio/tonic-dependent snix crates NOT portable to Redox — only snix-eval, nix-compat (sync)
