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

## Phase 2.6: cargo build on Redox ✅ (41/41 self-hosting tests pass)
- [x] Fixed abort() ud2 → clean _exit(134) (patch-relibc-abort-dso.py)
- [x] Fixed CWD mutex deadlock after fork (patch-relibc-chdir-deadlock.py)
- [x] Fixed ld_so p_align=0 division by zero (patch-relibc-ld-so-align.py)
- [x] Fixed build script pipe hang — thread-based read2 (patch-cargo-read2-pipes.py)
- [x] Fixed env var propagation — --env-set workaround (patch-cargo-env-set.py)
- [x] Fixed response file handling in CC wrapper (serde_derive proc-macro linking)
- [x] Fixed blake3 build script C compiler hang (patch in snix-source-bundle)
- [x] Fixed relative path resolution (rustc-abs wrapper, patch-cargo-redox-paths.py)
- [x] Full snix self-compile: 168 crates, 83MB binary, eval verification on Redox
- [x] Proc-macros, vendored deps, path deps, build scripts — all working

### Remaining workarounds:
- [x] **ld_so cwd bug — FIXED**: patch-relibc-ld-so-cwd.py injects CWD via
      __relibc_init_cwd_ptr/len. Deadlock fix: drop() guard before set_cwd_manual().
      **rustc-abs wrapper removed.** All tests pass with direct rustc.
- [x] **fcntl lock — FIXED**: patch-relibc-fcntl-lock.py makes F_SETLK/F_SETLKW/F_GETLK
      no-ops. Prevents fcntl-based hangs in cargo.
- [ ] **exec() env var propagation**: Using --env-set CLI flag (patch-cargo-env-set.py).
- [ ] **Intermittent cargo hangs**: cargo-build-safe (90s timeout + retry) still needed.
      Not flock or fcntl — some other blocking operation in cargo startup.
- [x] **JOBS>1 reliability**: JOBS=4 hangs after ~115 crates. JOBS=1 works reliably.

## Phase 3: Native Build Capability
- [x] **Implement `derivationStrict` in snix-eval** — eval-only, computes store paths (Phase 1)
- [x] **Local unsandboxed build execution** — `build_derivation()` via Command (Phase 2)
- [x] **Reference scanning** — `scan_references()` finds store path hashes in outputs
- [x] **NAR hashing** — `nar_hash_path()` for PathInfoDb registration
- [x] **Dependency resolution** — topological sort + `build_needed()` for dependency chains
- [x] **`snix build` CLI command** — `snix build --expr '...'` evaluates + builds + prints output
- [x] **`SnixRedoxIO` EvalIO wrapper** — store-aware IO with build-on-demand (IFD)
- [x] **Upgrade bridge to derivation-level protocol** — `build-attr` and `build-drv` request types
- [x] **Cargo vendoring** — `snix vendor setup/info/check/link` (offline builds)

## Test Results Summary
- **303 host unit tests** — all pass (snix-redox crate)
- **50/50 self-hosting VM tests** — all pass (JOBS=1)
  - 14 toolchain presence, 16 compilation, 16 cargo workflows, 4 snix self-compile
  - snix self-compile: 168 crates → 83MB binary → eval verification on Redox (6m 43s)
- **relibc patches**: 8 total (ns-fd, run-init, prefault-stack, grow-main-stack, chdir-deadlock, abort-dso, ld-so-align, ld-so-cwd)
- **cargo patches**: 4 total (read2-pipes, env-set, redox-paths ×2)
- **rustc patches**: 4 total (main-stack, linker-pipes, spawn-pipes, read2-pipes)

## Architecture Notes
- CWD injection in ld_so eliminates the #1 workaround (rustc-abs wrapper)
- JOBS=1 required for reliable compilation (pipe handling limitation)
- Bridge pattern (guest evaluates, host builds) for complex packages
- Native `snix build` for simple derivations on-guest
