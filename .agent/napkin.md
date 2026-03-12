# Napkin — Redox OS Build System

Active corrections and recurring mistakes. Permanent knowledge lives in AGENTS.md.

## Recurring Mistakes (STILL catch me)

### New files must be `git add`ed for flakes
- Every session. New `.nix` or `.rs` files invisible to `nix build` until tracked.

### Nix `''` string terminators
- `''` in Python code, `echo ''`, `get('key', '')` — all terminate the Nix string.
- Use `""`, `echo ""`, `str()` respectively.

### Heredoc indentation in Nix `''` strings
- ONE column-0 line breaks ALL heredoc terminators. Every line needs ≥N spaces for N-space stripping.
- `nix fmt` can silently re-indent and break heredocs. Verify after formatting.
- **Inline Python in Nix strings breaks too**: `python3 -c "..."` and `python3 << 'EOF'` heredocs
  get their indentation shifted by Nix stripping. Extract to .py files instead.

### Comments containing `''` in Nix strings
- `# heredocs in Nix '' strings break` → the `''` terminates the Nix string.
- Reword comments to avoid consecutive single quotes.

### Vendor hash must update in BOTH files
- `snix.nix` AND `snix-source-bundle.nix` need the same hash when Cargo.lock changes.

### Ion `$()` crashes on empty output
- `let var = $(grep ...)` → "Variable '' does not exist" when grep returns nothing.
- Use file-based or exit-code-based testing instead.

### `tail` does not exist on Redox
- Test scripts using `tail -c 4096 /tmp/log` fail silently — no output.
- Use `cat` or `head` (from extrautils) instead.

### Cargo build pipe exit codes lost on Redox
- `cargo build 2>&1 | while read` always exits 0 on Redox (pipe breaks).
- Use file redirection instead: `cargo build > /tmp/log 2>&1 &`
- Then `wait $PID` to get cargo's real exit code.

### `mod build_proxy` must be in BOTH lib.rs AND main.rs
- snix-redox has separate lib and bin crates with their own module trees.
- Adding a module to lib.rs but not main.rs causes unresolved import errors
  when the bin crate's modules reference it.

### /etc/snix/config must be read by snix
- Module system writes `sandbox=disabled` to `/etc/snix/config`.
- snix previously ignored this — sandbox was always CLI-flag-only.
- Added `sandbox_disabled_by_config()` to read config + SNIX_NO_SANDBOX env.

### Nix derivation caching vs. dirty flake tree
- Nix flakes evaluate from the git working tree but cache based on content hash.
- `git add` alone doesn't force re-evaluation. If the derivation input hash hasn't changed
  (because the file was already tracked with same content), nix reuses the cached build.
- When debugging "my patch didn't take effect": check if the drv path actually changed
  with `nix eval --raw '.#pkg.drvPath'` before and after.

## Stale Claims (verified fixed)

### Kernel DMA page allocator bug (FIXED 2026-03-12)
- `zeroed_phys_contiguous` now initializes ALL 2^order frames via `patch-kernel-p2frame-init.py`.
- `handle_free_action` uses bulk `deallocate_p2frame(base, order)` instead of per-frame loop.
- `alloc_order: Option<u32>` added to `Provider::Allocated` to track actual allocation size.
- `round_to_p2_pages()` in virtio-fsd retained as defense in depth.
- Verified: boot-test passes, bridge-test passes (41/42, 1 pre-existing unrelated failure).

### nanosleep works correctly (2026-03-11)
- SYS_NANOSLEEP (syscall 162) properly implemented: sets context.wake + context.block.
- No `sleep` binary exists (not compiled in uutils), but `read -t N` works in bash.

### Heredoc terminators in Nix '' strings (FIXED 2026-03-11)
- 120 heredoc terminators across 45 .nix files fixed.
- Added broad treefmt + git-hooks excludes for .nix files with heredocs.

### ld.so argv UTF-8 parsing (FIXED)
- `patch-relibc-ld-so-argv-utf8.py` uses `to_string_lossy()` instead of `_exit(1)`.

### Clang fork -cc1 on Redox (FIXED)
- CC wrapper passes `-no-canonical-prefixes` + explicit `-resource-dir`.
- `cc-rs` crate needs `AR=llvm-ar`.

### JOBS>1 parallel cargo builds (FIXED 2026-03-12)
- Two root causes found and fixed:
  (1) lld stack overflow at JOBS>=2 → `lld-wrapper` (16MB stack thread + exec)
  (2) cargo job manager hang on multi-crate workspaces → `patch-relibc-fork-lock.py`
      (futex-based CLONE_LOCK replaced with AtomicI32 + sched_yield)
- Validated 2026-03-12: JOBS=2, 100-crate workspace built in 240s. All 12 parallel-build-test PASS.
- Full test suite validated 2026-03-12: ALL self-hosting tests bumped to JOBS=2.
  57/58 PASS (snix 193 crates, ripgrep 33 crates, all individual cargo tests).
  Only failure: parallel-jobs2 (cc-wrapper linker crash, pre-existing).
- WAS previously listed as "JOBS=1 workaround needed" and "linker crash, NOT a hang" — both wrong.

### DSO environ injection partially working (2026-03-12)
- Added `__relibc_init_environ` to version script global section (rustc-redox.nix + redox-sysroot.nix).
- `libc.so` now exports `__relibc_init_environ` as global BSS symbol.
- ld.so binding check relaxed from `SymbolBinding::Global` to `_` (any binding).
- Validated: `cargo-buildrs:PASS` and `cargo-proc-macro:PASS` without --env-set patch.
- Basic cargo→rustc env propagation through DSO-linked rustc works.

## Active Workarounds (still needed)

### --env-set for cargo (still needed — environ universally broken)
- `patch-cargo-env-set.py` passes env vars via rustc `--env-set` flag.
- Environ propagation is universally broken for DSO-linked rustc on Redox.
- `option_env!("LD_LIBRARY_PATH")` returns None even for simple cargo builds.
- --env-set covers CARGO_PKG_*, OUT_DIR, and cargo:rustc-env values.
- Ring fails because it needs env!("CARGO_PKG_NAME") which IS in --env-set,
  but the ring build also exercises paths where process environ matters.
- Without --env-set: tests that use env!("CARGO_PKG_NAME") fail across the board.
- With --env-set: 48/50+ pass (only env-propagation tests fail — by design).
- Removal condition: fix DSO environ propagation in ld_so/relibc.

### cargo-build-safe timeout wrapper
- 90s timeout + retry for intermittent cargo hangs (flock and other blocking).

### Stdio::inherit() for build_derivation on Redox
- `cmd.output()` creates pipes that crash deep process hierarchies (snix→bash→cargo→rustc→cc→lld).
- `#[cfg(target_os = "redox")]` uses `Stdio::inherit()` + `.status()` instead.

## Active Bugs (not yet fixed)

### Self-hosting test parallel-jobs2 linker crash (exit=101)
- `cargo build` with JOBS=2 in self-hosting test: `cc` wrapper linker crashes with
  `fatal runtime error: failed to initiate panic, error 0` / `relibc: abort() called`.
- This is the `cc` wrapper path (cargo config uses `linker = cc`), NOT `ld.lld` directly.
- The `lld-wrapper` fix only applies when lld is invoked as a standalone process.
  When lld runs INSIDE clang (via cc wrapper), it doesn't get the 16MB stack.
- The parallel-build-test (100 crates, JOBS=2) uses `linker = ld.lld` and PASSES.
- Fix: either make cc wrapper use lld-wrapper, or grow clang's stack for the lld thread.

### Kernel DMA page allocator bug (FIXED — see Stale Claims)
- Fixed via `patch-kernel-p2frame-init.py`. See "Stale Claims" section below.

### Environ propagation: DSO chain correct, env!() still fails (2026-03-12)
- PROVEN by env!() compile error: `environment variable 'DIAG_TEST_VAR' not defined at compile time`
- PROVEN by ld_so diagnostic: DIAG_TEST_VAR IS in ld_so environ at index 2 (of 15 vars)
- Full symbol chain verified via disassembly:
  - DSO's getenv (local, 0x7988c90) reads GOT[0x8058e90] → 0x80ebcb0 (environ addr)
  - GOT has R_X86_64_RELATIVE relocation pointing to DSO's environ at 0x80ebcb0
  - init_array writes to platform::environ which IS the symbol at 0x80ebcb0
  - Same address! getenv reads from what init_array wrote to.
- DSO's std::env::var_os → calls DSO's local getenv (R_X86_64_RELATIVE, not PLT)
- DSO's getenv → reads DSO's local environ at 0x80ebcb0 (confirmed by relocation)
- init_array → writes to DSO's platform::environ at 0x80ebcb0 (confirmed by diagnostic)
- EVERYTHING IS CORRECT but env!() still can't find the var
- Remaining hypothesis: TIMING — something clears DSO's environ between init_array
  and macro expansion. Candidates:
  (a) relibc_start_v1's init_array() call (line 220 in start.rs) — runs AFTER the
      DSO init_arrays already ran, could it reset DSO's environ?
  (b) A second DSO's init_array overwrites the first DSO's environ with null
  (c) The main binary's CRT setup zeroes BSS (including DSO's BSS?) — unlikely
  (d) Memory corruption from ld_so handing off to main binary
- ALSO: compiled test binaries crash at RIP=0x0 — ld.lld "cannot find entry symbol _start"
  even with --crate-type bin. Need to fix this separately.

## Redox Namespace Sandboxing (implemented)

### How mkns/setns work
- `mkns` creates a new namespace via `dup(current_ns_fd, buf)` — NOT a raw syscall.
- `setns` is userspace-only — swaps `DynamicProcInfo.ns_fd`, no kernel call.
- Namespace filtering is **scheme-level only** — `file:` is all-or-nothing.

### snix sandbox implementation
- Normal builds: `file`, `memory`, `pipe`, `rand`, `null`, `zero`.
- FODs: also `net`.
- Falls back on ENOSYS (old kernel) — continues unsandboxed.
- Per-path filtering needs proxy scheme daemon (future).

## unit2nix Migration (2026-03-12)

### 11 Rust packages migrated from mk-userspace to per-crate builds
- ripgrep, bat, fd, hexyl, zoxide, dust, tokei, lsd, shellharden, smith, exampled
- crossBuild infrastructure now lives in packages.nix (single source of truth)
- checks.nix cross-check aliases reference packages.* directly
- Old per-package .nix files deleted (-785 lines)
- `pname` attribute set via `//` on unit2nix output for image builder compatibility
  (`pkg.pname or (builtins.parseDrvName pkg.name).name` — unit2nix names are `rust_NAME`)
- tokei, lsd, shellharden, smith, exampled now wired into extraPkgs + development profile

### strace-redox auto-vendor broken (FIXED 2026-03-12)
- `libc` crate was a git dependency (`gitlab.redox-os.org/redox-os/liblibc.git?branch=rust-2022-03-18`)
- Auto-vendor (`unit2nixVendor`) only handles crates.io registry deps, not git deps
- Fix: switched to `vendorHash` + `gitSources` (same pattern as findutils, contain, etc.)

## TLS / ring Cross-Compilation

### ring 0.17 from crates.io works for Redox (cross-compile only)
- ring 0.17.14 cross-compiles to x86_64-unknown-redox via the Nix CC wrapper.
- NO need for the Redox fork.
- `cargo check --target x86_64-unknown-redox` in devshell FAILS (picks up host glibc) — only Nix build works.
- Self-hosted ring compilation fails (see active bug above).
