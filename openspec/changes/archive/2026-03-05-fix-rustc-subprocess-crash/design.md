## Context

When cargo builds a project with `build.rs` on Redox, rustc crashes with "Invalid opcode fault" (ud2) inside `abort()` in librustc_driver.so. The crash sequence:

1. Something in rustc panics during initialization for build-script compilation
2. `panic_with_hook` → `abort()` is called (because `panic=abort`)
3. `abort()` loads a function pointer from a GOT-relative address
4. The pointer resolves to a BSS-initialized zero (the relocation targets `log::MAX_LOG_LEVEL_FILTER` or similar zero-init static)
5. NULL check → `je ud2` → kernel kills process with "Invalid opcode fault"

The crash is deterministic at RIP offset `0x79cc882` in librustc_driver.so's bundled relibc `abort()` function. addr2line on the stack frames shows: `gethostent` (frame 0), `Backtrace::create` (frame 1), `panic_with_hook` (frame 3), though frame pointers may be unreliable.

Key observation: `cargo build` of projects WITHOUT `build.rs` works. The presence of `build.rs` changes cargo's internal code path (build script compilation + execution planning) which triggers the crash.

## Goals / Non-Goals

**Goals:**
- Make `abort()` in DSO copies of relibc produce useful diagnostics (exit code + optional message) instead of silent ud2
- Determine exactly WHICH rustc command triggers the panic (cargo -vv output capture)
- Fix the root cause so `cargo build` with `build.rs` succeeds
- Validate with the self-hosting test: `cargo-buildrs:PASS`

**Non-Goals:**
- Full rework of DSO relibc initialization (that's a larger project)
- Fixing all possible abort/panic paths in DSOs (just the critical path for cargo)
- Upstream relibc changes (we're on a pinned commit)

## Decisions

**1. Patch abort() to use `_exit(134)` instead of ud2**

When the abort hook pointer is NULL (uninitialized in DSO), call `syscall::exit(134)` directly instead of executing `ud2`. 134 = 128 + SIGABRT(6), the conventional exit code for abort. This lets the parent process (cargo) detect the child failed and report an error, rather than the kernel printing an opaque register dump.

Alternative: Initialize the abort hook during DSO loading (via `__relibc_init_abort_hook` similar to `__relibc_init_ns_fd`). This is more correct but invasive — requires changes to ld_so's run_init and DSO symbol resolution. We may add this as a follow-up.

**2. Add `/etc/hosts` to the disk image**

`gethostent()` opens `/etc/hosts` via `Sys::open(c"/etc/hosts", O_RDONLY, 0)`. If the file doesn't exist, the open fails, and subsequent code may panic on unwrap. A minimal `/etc/hosts` with `127.0.0.1 localhost` prevents this failure path.

**3. Diagnostic-first approach for Step 10**

Before attempting the fix, add `cargo build -vv` output capture to Step 10 to see the exact rustc invocation that triggers the crash. Then replicate that exact command manually (via rustc-abs) to isolate whether it's a cargo subprocess issue or a rustc argument issue.

**4. Investigate the actual panic cause**

Once abort() produces clean exits instead of ud2, the cargo error output will reveal what went wrong. The panic could be:
- `gethostent` failure (no /etc/hosts)
- Allocator lock contention (same post-fork stale mutex pattern as CWD)
- Thread-local storage access in tracing initialization
- Missing scheme access for `/scheme/rand` or `/scheme/sys`

## Risks / Trade-offs

**[Risk: abort() patch masks real bugs]** → The `_exit(134)` approach is strictly better than `ud2` for debugging. We're not hiding the crash — we're making it reportable to the parent process. The kernel register dump is useless to cargo.

**[Risk: /etc/hosts isn't the real cause]** → Even if gethostent isn't the trigger, having `/etc/hosts` is good hygiene. Many network utilities expect it. Zero cost.

**[Risk: Multiple cascading issues]** → The abort hook NULL, the potential gethostent panic, and the potential allocator stale lock could all be separate problems. We may need to fix them one at a time, rebuilding between each. Mitigation: diagnostic-first approach lets us see the next error after each fix.

**[Risk: DSO allocator mutex is also stale after fork]** → The same pattern as the CWD Mutex deadlock. `path::open()` uses the allocator (for String allocation in `canonicalize_with_cwd_internal`), and the DSO's allocator Mutex could be inherited locked from the parent. The `gethostent` disassembly shows dlmalloc lock acquisition via CAS spin loop. If this is the trigger, we'd need a similar try_lock+force_unlock patch for the allocator. But this would be in the DSO's SEPARATE allocator instance, not the main binary's.
