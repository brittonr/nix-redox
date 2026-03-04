# Self-Hosting Plan

## Phase 1: Bridge Rebuild Loop ✅ (completed Mar 2 2026)
- [x] Guest writes RebuildConfig JSON to shared filesystem
- [x] Host daemon picks up request, builds rootTree via bridge-eval.nix
- [x] Host exports binary cache (NAR + narinfo) to shared dir
- [x] Guest polls, installs packages, activates new generation
- [x] Integration test: 11/11 passing (bridge-rebuild-test)

## Phase 2: Expand Toolchain on Redox ✅ (cross-compilation done)
- [x] Cross-compile cmake 3.31.0 for Redox (19MB static ELF)
- [x] Cross-compile LLVM 21.1.2 (clang 91MB, lld 57MB, llvm-ar 11MB)
- [x] Cross-compile Rust compiler (rustc 284K + 180MB librustc_driver.so)
- [x] Cross-compile cargo (41MB static ELF)
- [x] Self-hosting profile with toolchain, sysroot, CC wrapper, cargo config
- [x] libstdcxx-shim: shared libc++ as libstdc++.so.6 (943 C++ ABI symbols)
- [x] relibc ld_so DSO process state injection — `rustc -vV` works on Redox
- [x] 8MB main thread stack via relibc patch (mmap + pre-fault + RSP switch)
- [x] Allocator shim (liballoc_shim.a) — 7 symbols wiring __rust_alloc → __rdl_alloc

## Phase 2.5: Two-Step Compile ✅ (working)
- [x] `rustc --emit=obj` works on-guest (LLVM codegen fully functional)
- [x] Two-step empty program: rustc --emit=obj + ld.lld → runs, exit 0
- [x] Two-step hello world: compiles, links, runs, prints "hello" correctly
- [x] CC wrapper (bash, not Ion) for ld.lld with CRT files
- [x] Stub libgcc_eh.a/libgcc.a (_Unwind_* no-ops for panic=abort)
- [x] Self-hosting test: 18/21 PASS, 3 FAIL (driver-so cosmetic, cargo-build, binary-exists)

## Phase 2.6: Fix cargo build (BLOCKED — subprocess crash)
- [ ] **Investigate cargo→rustc crash**: rustc crashes with Invalid opcode when invoked
      by cargo as subprocess. NOT in fork/waitpid — crash is in rustc's initialization
      (tracing_tree::FmtEvent::record_bytes). Individual rustc operations all work from shell.
- [ ] Compare environment: what does cargo set that the shell doesn't?
- [ ] Check if CARGO_MAKEFLAGS, CARGO_TARGET_DIR, or other cargo env vars trigger it
- [ ] Try: cargo with `RUSTC_LOG=off`, `RUST_BACKTRACE=0`
- [ ] Try: replicate cargo's exact rustc invocation from the shell
- [ ] Fix librustc_driver.so detection (cosmetic test failure)

## Phase 3: Native Build Capability
- [ ] **Implement `derivationStrict` in snix-eval** — produce .drv files on guest
- [ ] **Cargo vendoring** — offline crate sources via virtio-fs or disk image
- [ ] **Upgrade bridge to derivation-level protocol** — guest sends .drv hashes, host builds
- [ ] **Native build support** — snix can invoke local rustc/cargo when available

## Architecture Notes
- Two-step compile (rustc --emit=obj + ld.lld) works around the subprocess crash
- Could build a "cargo wrapper" that uses two-step internally (compile without link, then link separately)
- The subprocess crash might be in ld_so initialization for child processes, or in Redox's fork COW
- Bridge pattern (guest evaluates, host builds) is the near-term path
- snix-eval lacks `derivationStrict` builtin — can't produce .drv files yet (Phase 3)
