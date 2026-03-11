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

### Vendor hash must update in BOTH files
- `snix.nix` AND `snix-source-bundle.nix` need the same hash when Cargo.lock changes.

### Ion `$()` crashes on empty output
- `let var = $(grep ...)` → "Variable '' does not exist" when grep returns nothing.
- Use file-based or exit-code-based testing instead.

## Recurring Mistakes (NEW)

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

### ld.so argv UTF-8 parsing bug (FIXED)
- WAS: `ld.so: failed to parse argv[N]` when --env-set passes non-ASCII characters.
- FIXED: `patch-relibc-ld-so-argv-utf8.py` uses `to_string_lossy()` instead of `_exit(1)`.
- Root cause was `get_argv` in `start.rs` calling `_exit(1)` on non-UTF-8 argv.
- Note: `get_env` already handled this gracefully with `if let Ok(...)`.

### Clang can't fork -cc1 on Redox (FIXED)
- Clang's `getMainExecutable` fails on Redox (no `/proc/self/exe`, `realpath` returns `file:/path`).
- `InstalledDir` becomes empty → exec of `""` fails → "unable to execute command".
- FIXED: CC wrapper passes `-no-canonical-prefixes` + explicit `-resource-dir`.
- Also needs `-isystem` for sysroot C headers (not `--sysroot` which overrides resource headers).
- `cc-rs` crate needs `AR=llvm-ar` (no bare `ar` binary on Redox).

### /etc/snix/config must be read by snix
- Module system writes `sandbox=disabled` to `/etc/snix/config`.
- snix previously ignored this — sandbox was always CLI-flag-only.
- Added `sandbox_disabled_by_config()` to read config + SNIX_NO_SANDBOX env.

## Active Workarounds (still needed)

### --env-set for cargo (PERMANENT until relibc DSO environ fix)
- `patch-cargo-env-set.py` passes env vars via rustc `--env-set` flag.
- Without it: thiserror-impl, serde_derive fail on `env!("CARGO_PKG_*")`.
- Removal condition: fix DSO environ initialization so all .so files share environ pointer.

### cargo-build-safe timeout wrapper
- 90s timeout + retry for intermittent cargo hangs (flock and other blocking).
- Not the same as CWD bug (fixed) or fcntl locks (patched to no-op).

### JOBS=1 for cargo on Redox
- JOBS>1 hangs after ~115-136 crates. Root cause unknown — not jobserver, not fcntl.
- Theories: waitpid notification, pipe deadlock, thread starvation, memory pressure.

### Stdio::inherit() for build_derivation on Redox
- `cmd.output()` creates pipes that crash deep process hierarchies (snix→bash→cargo→rustc→cc→lld).
- `#[cfg(target_os = "redox")]` uses `Stdio::inherit()` + `.status()` instead.

## Active Bugs (not yet fixed)

### Redox exec() env propagation
- `Command::env()` vars don't propagate through exec for DSO-linked binaries.
- `execvpe()` added but doesn't fully fix it for proc-macro crates.
- Workaround: `--env-set` (see above).

### Kernel DMA page allocator bug
- `zeroed_phys_contiguous` only initializes `span.count` pages, not full 2^order allocation.
- Buddy allocator corruption on dealloc. Workaround: `round_to_p2_pages()` + `mem::forget()`.
- Upstream kernel fix needed.

### Parallel cargo compilation hangs
- See JOBS=1 workaround above. Needs OS-level investigation.

## Redox Namespace Sandboxing (implemented)

### How mkns/setns work
- `mkns` creates a new namespace via `dup(current_ns_fd, buf)` — NOT a raw syscall.
- Wire format: `[NsDup::ForkNs (8 bytes LE)] [name_len (8 bytes LE)] [name_bytes] ...`
- `setns` is userspace-only — swaps `DynamicProcInfo.ns_fd`, no kernel call.
- Namespace filtering is **scheme-level only** — `file:` is all-or-nothing.

### libredox API
- `libredox::call::mkns(&[IoSlice])` — needs `mkns` feature (pulls in `ioslice` crate).
- `libredox::call::setns(fd)` — switches process namespace.
- `libredox::call::setrens(0, 0)` — creates null namespace (memory+pipe only), used by virtio-fsd.
- Error type: `libredox::error::Error`, errno via `.errno()`, constants in `libredox::errno::*`.

### snix sandbox implementation
- Normal builds: `file`, `memory`, `pipe`, `rand`, `null`, `zero`.
- FODs: also `net`.
- Falls back on ENOSYS (old kernel) — continues unsandboxed.
- Runs in `pre_exec` closure (between fork and exec).
- Per-path filtering (restrict file: to $out+$TMPDIR) needs proxy scheme daemon (future).

## TLS / ring Cross-Compilation

### ring 0.17 from crates.io works for Redox
- ring 0.17.14 cross-compiles to x86_64-unknown-redox via the Nix CC wrapper.
- NO need for the Redox fork at gitlab.redox-os.org/redox-os/ring.
- The Nix build provides the relibc sysroot; ring's build.rs finds it via clang --target.
- `cargo check --target x86_64-unknown-redox` in devshell FAILS (picks up host glibc) — only Nix build works.
- ureq 3.0 features = ["rustls"] pulls in rustls 0.23 + ring 0.17 + webpki-roots.
- Binary size: ~6.6MB statically linked (release + LTO + panic=abort).
