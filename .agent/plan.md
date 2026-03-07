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

### Remaining workarounds (not blockers, but would remove wrapper scripts):
- [x] **ld_so cwd bug**: Root cause: each DSO gets its own path::CWD static = None.
      Fix: patch-relibc-ld-so-cwd.py injects CWD via __relibc_init_cwd_ptr/len
      (same pattern as ns_fd/proc_fd). Should remove need for rustc-abs wrapper.
- [ ] **exec() env var propagation**: cargo:rustc-env vars don't propagate through
      Redox exec(). Using --env-set CLI flag as workaround (patch-cargo-env-set.py).
      Root cause: relibc's do_exec → execve env handling.
- [ ] **flock() hangs**: cargo's .package-cache flock sometimes hangs forever.
      Using cargo-build-safe wrapper with timeout+retry.
- [ ] **JOBS>1 reliability**: parallel compilation (CARGO_BUILD_JOBS=4) works for
      the snix self-compile but was historically unreliable. May need further testing.

## Phase 3: Native Build Capability
- [x] **Implement `derivationStrict` in snix-eval** — eval-only, computes store paths (Phase 1)
- [x] **Local unsandboxed build execution** — `build_derivation()` via Command (Phase 2)
- [x] **Reference scanning** — `scan_references()` finds store path hashes in outputs
- [x] **NAR hashing** — `nar_hash_path()` for PathInfoDb registration
- [x] **Dependency resolution** — topological sort + `build_needed()` for dependency chains
- [x] **`snix build` CLI command** — `snix build --expr '...'` evaluates + builds + prints output
- [x] **`SnixRedoxIO` EvalIO wrapper** — store-aware IO with build-on-demand (IFD)
- [x] **Upgrade bridge to derivation-level protocol** — `build-attr` and `build-drv` request types
- [ ] **Cargo vendoring** — offline crate sources via virtio-fs or disk image

## Architecture Notes
- Two-step compile (rustc --emit=obj + ld.lld) works around the subprocess crash
- Could build a "cargo wrapper" that uses two-step internally (compile without link, then link separately)
- The subprocess crash might be in ld_so initialization for child processes, or in Redox's fork COW
- Bridge pattern (guest evaluates, host builds) is the near-term path
- snix-eval lacks `derivationStrict` builtin — can't produce .drv files yet (Phase 3)
