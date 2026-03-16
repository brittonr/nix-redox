# Napkin — Redox OS Build System

Active corrections and recurring mistakes. Permanent knowledge lives in AGENTS.md.

## Recurring Mistakes

### New files must be `git add`ed for flakes
- Every session. New `.nix` or `.rs` files invisible to `nix build` until tracked.

### Nix `''` string terminators
- `''` in Python code, `echo ''`, `get('key', '')` — all terminate the Nix string.
- Use `""`, `echo ""`, `str()` respectively.
- Comments containing `''` also break — reword to avoid consecutive single quotes.

### Heredoc indentation in Nix `''` strings
- ONE column-0 line breaks ALL heredoc terminators. Every line needs N+ spaces for N-space stripping.
- `nix fmt` can silently re-indent and break heredocs. Verify after formatting.
- Inline Python in Nix strings breaks too — extract to .py files instead.

### Vendor hash must update in BOTH files
- `snix.nix` AND `snix-source-bundle.nix` need the same hash when Cargo.lock changes.

### `cp -r dir/*` drops dotfiles
- Use `cp -r dir/.` to copy ALL contents including dotfiles.
- `.cargo/config.toml` silently lost when `/*` was used.

### `mod build_proxy` must be in BOTH lib.rs AND main.rs
- snix-redox has separate lib and bin crates with their own module trees.

### Nix derivation caching vs. dirty flake tree
- `git add` alone doesn't force re-evaluation if content hash hasn't changed.
- Check with `nix eval --raw '.#pkg.drvPath'` before and after to confirm drv changed.

## Active Workarounds (still needed)

### Poll-wait pattern for cargo builds
- Redox waitpid via proc: scheme hangs when parent is idle on KVM.
- Background cargo + `kill -0` poll loop with scheme I/O + `wait $PID`.

### Stdio::inherit() for build_derivation on Redox
- `cmd.output()` creates pipes that crash deep process hierarchies.
- `#[cfg(target_os = "redox")]` uses `Stdio::inherit()` + `.status()`.

### Proxy scheme socket close doesn't unblock next_request()
- Closing scheme socket fd from another thread does NOT unblock blocked `next_request()`.
- Event loop checks `handler.handles.is_empty()` and exits when builder exits.

### child_ns_fd must be closed in parent after spawn
- mkns() fd shared by parent and child. Parent must close its copy after spawn.
- Do NOT close in child's pre_exec — setns() stores the raw fd as current namespace.

### thread::sleep() deadlocks with scheme I/O
- Use sched_yield() instead of thread::sleep() in poll-wait loops on Redox.

### Rust stdout not flushed on Redox process exit
- Explicit `stdout().flush()` required before process exit.

## Ion Shell Gotchas (keep forgetting)

### `$()` crashes on empty output
- `let var = $(grep ...)` → "Variable '' does not exist" when grep returns nothing.
- Use file-based or exit-code-based testing instead.

### `tail` does not exist on Redox
- Use `cat` or `head` (from extrautils) instead.

### Cargo build pipe exit codes lost
- `cargo build 2>&1 | while read` always exits 0 (pipe breaks).
- Use file redirection + `wait $PID` to get real exit code.
