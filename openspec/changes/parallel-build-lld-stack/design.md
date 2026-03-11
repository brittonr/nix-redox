## Context

The Redox kernel allocates ~8KB of stack for a process's main thread. This is far too small for lld, which recurses heavily during symbol resolution and section layout. `patch-rustc-main-stack.py` already fixes this for rustc by spawning a 16MB-stack thread before calling `rustc_driver::main()`. The cc wrapper has no equivalent — it either `exec()`s lld directly (compiled variant) or runs lld as a background process (bash variant), both inheriting the kernel's tiny main-thread stack.

With JOBS=1, the single linker invocation happens to survive (barely). With JOBS=2, memory pressure from two concurrent processes tips lld over the stack limit, producing:

```
fatal runtime error: failed to initiate panic, error 0, aborting
relibc: abort() called
```

Exit code 101. The crash is deterministic — even `fn main() { println!("hello"); }` triggers it under JOBS=2.

Two cc wrapper implementations exist:
1. **Bash script** in `redox-sysroot.nix` — the production wrapper used by cargo/rustc on Redox. Runs lld via `"$LLD" ... &` then `wait $pid`.
2. **Compiled binary** in `cc-wrapper-redox.nix` — uses `CommandExt::exec()` to replace the process with lld. Currently unused in production but kept as an alternative.

## Goals / Non-Goals

**Goals:**
- Give lld a large thread stack (16MB) so it does not overflow under parallel link invocations.
- Enable JOBS=2 for cargo builds on Redox without crashes.
- Keep the fix minimal — same pattern already proven by `patch-rustc-main-stack.py`.

**Non-Goals:**
- Kernel changes to increase default main-thread stack size (separate, longer-term effort).
- Raising JOBS beyond 2 in this change (validate 2 first, tune later).
- Applying stack growth to other programs (clang, etc.) — only lld is crashing.

## Decisions

### 1. Compiled launcher binary that spawns lld on a big-stack thread

**Choice**: Write a small Rust binary (`lld-wrapper`) that spawns a 16MB-stack thread, then `exec()`s lld from that thread. The bash cc wrapper calls this binary instead of invoking lld directly.

**Alternatives considered**:
- **Modify the bash wrapper to use a `ulimit -s` call**: Redox doesn't support `setrlimit` / `ulimit` for stack.
- **Grow the stack in the bash cc wrapper itself**: Bash has no mechanism to control child thread stack size. The lld process inherits the kernel default regardless.
- **Patch lld source to spawn a big-stack thread**: Invasive, hard to maintain across LLVM version bumps.
- **Use `pthread_attr_setstacksize` via a C shim**: Possible, but Rust's `thread::Builder::stack_size` is cleaner and matches the rustc precedent.

**Rationale**: A tiny compiled wrapper is the least invasive option. It matches the proven `patch-rustc-main-stack.py` pattern, doesn't touch lld or kernel sources, and composes with the existing bash cc wrapper.

### 2. 16MB stack size

Same value used for rustc. lld's stack usage is comparable (deep recursion in ELF linker). No measurement needed — 16MB is generous and matches precedent.

### 3. Modify bash wrapper, not the compiled cc-wrapper-redox.nix

The bash script in `redox-sysroot.nix` is the production cc wrapper. The compiled `cc-wrapper-redox.nix` is currently unused. Change the bash wrapper to call lld through the launcher. Update the compiled wrapper too for consistency, switching from `exec()` to the spawn-thread pattern.

## Risks / Trade-offs

- **[Risk] Thread spawn overhead**: Each link invocation spawns a thread, adding ~microseconds. → Negligible compared to lld's runtime (seconds).
- **[Risk] Stack size too small for pathological inputs**: 16MB could still overflow for extremely large link jobs. → Same risk as rustc; 16MB has been sufficient in practice. Can increase later if needed.
- **[Risk] `thread::spawn` + `exec` interaction on Redox**: The spawned thread calls `exec()`, which replaces the entire process. The main thread must not race. → Main thread joins the spawned thread (or just waits forever). `exec()` replaces the whole process anyway, so the main thread is irrelevant after exec succeeds.
