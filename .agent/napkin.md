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

### Self-hosting test parallel-jobs2 linker crash (FIXED 2026-03-13)
- Was crashing with `fatal runtime error: failed to initiate panic, error 0`.
- Previous napkin claimed "lld runs INSIDE clang" — WRONG. The cc wrapper calls lld-wrapper
  directly (not clang for linking). The crash was the fork-lock bug, not a stack issue.
- Fixed by patch-relibc-fork-lock.py (yield-based CLONE_LOCK).
- Validated: self-hosting-test 62/62 PASS including parallel-jobs2 (2026-03-13).

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
- Validated 2026-03-13: self-hosting-test 62/62 PASS at JOBS=2 (snix 193 crates, ripgrep 33 crates,
  parallel-jobs2, all individual cargo tests). No failures.
- WAS previously listed as "JOBS=1 workaround needed" and "linker crash, NOT a hang" — both wrong.

### DSO environ injection partially working (2026-03-12)
- Added `__relibc_init_environ` to version script global section (rustc-redox.nix + redox-sysroot.nix).
- `libc.so` now exports `__relibc_init_environ` as global BSS symbol.
- ld.so binding check relaxed from `SymbolBinding::Global` to `_` (any binding).
- Validated: `cargo-buildrs:PASS` and `cargo-proc-macro:PASS` without --env-set patch.
- Basic cargo→rustc env propagation through DSO-linked rustc works.

## Active Workarounds (still needed)

### --env-set for cargo (defense-in-depth — DSO environ now fixed)
- `patch-cargo-env-set.py` passes env vars via rustc `--env-set` flag.
- DSO environ propagation FIXED (2026-03-13) by `patch-relibc-environ-dso-init.py`:
  broadcasts environ to __relibc_init_environ after relibc_start_v1.
- Combined with getenv self-init (patch-relibc-dso-environ.py), DSOs now see
  the full process environ. env-propagation-simple and env-propagation-heavy PASS.
- --env-set kept as defense-in-depth (second path for env vars to reach rustc).
- Can be removed once DSO environ has more runtime mileage.

### cargo-build-safe timeout wrapper
- 90s timeout + retry for intermittent cargo hangs (flock and other blocking).

### Stdio::inherit() for build_derivation on Redox
- `cmd.output()` creates pipes that crash deep process hierarchies (snix→bash→cargo→rustc→cc→lld).
- `#[cfg(target_os = "redox")]` uses `Stdio::inherit()` + `.status()` instead.

## Active Bugs (not yet fixed)

### Kernel DMA page allocator bug (FIXED — see Stale Claims)
- Fixed via `patch-kernel-p2frame-init.py`. See "Stale Claims" section below.

### FIXED: DSO environ — full fix with __relibc_init_environ broadcast (2026-03-13)
- **ROOT CAUSE**: ld_so's run_init() writes platform::environ (NULL at load time) into
  each DSO's __relibc_init_environ. Later, relibc_start_v1 sets platform::environ
  from kernel envp, but __relibc_init_environ is never updated. DSOs see NULL via
  GLOB_DAT to main binary's copy.
- **FIX** (two patches):
  1. patch-relibc-environ-dso-init.py — in relibc_start_v1, after setting environ,
     also writes `__relibc_init_environ = platform::environ`. DSOs see this via GLOB_DAT.
  2. patch-relibc-dso-environ.py — getenv() self-initializes from __relibc_init_environ
     when environ is null (lazy init on first getenv call in DSO).
- **RESULT**: 62/62 tests pass. env-propagation-simple and env-propagation-heavy both PASS.
  option_env!("LD_LIBRARY_PATH") works in librustc_driver.so.
- Diagnostic patches (environ-diag.py, getenv-diag.py) removed from production build.

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
