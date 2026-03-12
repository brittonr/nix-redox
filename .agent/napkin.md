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
- WAS previously listed as "JOBS=1 workaround needed" and "linker crash, NOT a hang" — both wrong.

### DSO environ injection partially working (2026-03-12)
- Added `__relibc_init_environ` to version script global section (rustc-redox.nix + redox-sysroot.nix).
- `libc.so` now exports `__relibc_init_environ` as global BSS symbol.
- ld.so binding check relaxed from `SymbolBinding::Global` to `_` (any binding).
- Validated: `cargo-buildrs:PASS` and `cargo-proc-macro:PASS` without --env-set patch.
- Basic cargo→rustc env propagation through DSO-linked rustc works.

## Active Workarounds (still needed)

### --env-set for cargo (still needed for ring crate)
- `patch-cargo-env-set.py` passes env vars via rustc `--env-set` flag.
- Partial fix landed (2026-03-12): DSO environ injection works for simple builds.
- Still needed: ring crate fails `env!("CARGO_PKG_NAME")` after build.rs fork+exec of cc/clang.
  The 510 errors are all "attribute value must be a literal" from `prefixed.rs` — ring's `prefix!()`
  macro uses `env!("CARGO_PKG_NAME")` for symbol prefixing, and gets "not defined at compile time".
- Hypothesis: build.rs fork+exec of cc corrupts environ state in parent cargo process,
  so subsequent rustc invocations for the lib target lose CARGO_PKG_* vars.
- Without --env-set: 49/59 self-hosting tests pass (10 fail — all ring/snix/rg-related).
- With --env-set: 57/58 pass (only parallel-jobs2 fails — separate linker issue).
- Removal condition: fix the post-build.rs environ corruption.

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

### Kernel DMA page allocator bug
- `zeroed_phys_contiguous` only initializes `span.count` pages, not full 2^order allocation.
- Buddy allocator corruption on dealloc. Workaround: `round_to_p2_pages()` + `mem::forget()`.
- Upstream kernel fix needed.

### ring env!("CARGO_PKG_NAME") fails in snix builds
- Even with `__relibc_init_environ` version script fix, ring crate fails when built via snix.
- The same cargo→rustc chain works for simpler crates (hello world, proc-macros, build.rs deps).
- Unique to ring: build.rs compiles ~30 C/asm files via cc crate (fork+exec clang many times)
  before rustc compiles the lib target. Something in that process corrupts environ.
- Blocked on: understanding why build.rs fork+exec affects parent cargo's environ for later rustc calls.

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

## TLS / ring Cross-Compilation

### ring 0.17 from crates.io works for Redox (cross-compile only)
- ring 0.17.14 cross-compiles to x86_64-unknown-redox via the Nix CC wrapper.
- NO need for the Redox fork.
- `cargo check --target x86_64-unknown-redox` in devshell FAILS (picks up host glibc) — only Nix build works.
- Self-hosted ring compilation fails (see active bug above).
