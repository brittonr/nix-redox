# Napkin — Redox OS Build System

Active corrections and recurring mistakes. Permanent knowledge lives in AGENTS.md.

## Recurring Mistakes

### Package partitioning uses derivation references, not name strings
- Boot vs managed partition uses `samePackage` (outPath equality), never pname/parseDrvName.
- `bootPackages` is built from `pkgs.*` references directly (pkgs.base, pkgs.ion, etc.).
- `selfHostingPackages` same pattern — pkgs.redox-rustc, pkgs.redox-llvm, etc.
- `managedPackages` = systemPackages filtered by `!isBootPkg` (derivation identity).
- If a package changes pname/name metadata, nothing breaks — we reference the derivation, not its name.
- Old `bootEssentialNames` string list eliminated entirely.

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

### Poll-wait pattern for sandbox builds — REMOVED
- Was reintroduced during per-path-sandbox work out of caution.
- Tested 2026-03-15: blocking wait() works. 53/62 tests pass, no hangs.
- waitpid is a direct kernel syscall (SYS_WAITPID), doesn't route through initnsmgr.
- LAPIC timer ensures scheduler delivers child-exit wake even with all CPUs in HLT.
- Removed try_wait+sched_yield, unified on child.wait() for all platforms.

### Proxy scheme socket close doesn't unblock next_request() (kernel bug)
- Closing scheme socket fd from another thread does NOT unblock blocked `next_request()`.
- Workaround: event loop checks `handler.handles.is_empty()` and exits when builder exits.
- Code: `snix-redox/src/build_proxy/lifecycle.rs` ~line 206.
- Upstream fix would be in kernel/redox-scheme — not actionable from here.

### Code patterns to maintain (not bugs, just Redox differences)

- **child_ns_fd close after spawn**: mkns() fd shared by parent and child. Parent must close its copy after spawn. Do NOT close in child's pre_exec — setns() stores the raw fd. Code: `local_build.rs` ~line 401.
- **stdout flush before exit**: Redox exit handlers may not flush stdout. Always `stdout().flush()` before process exit. Code: `local_build.rs` ~line 1143.
- **sched_yield over thread::sleep**: thread::sleep uses nanosleep which routes through scheme I/O — deadlocks if initnsmgr is busy. Only matters in poll loops during sandbox builds.

## Known Sandbox Issues (per-path proxy)

### Build scripts denied by AllowList — FIXED (2026-03-15)
- Root cause: AllowList missing `/bin`, `/usr/bin` (bash PATH lookup got EACCES
  instead of ENOENT → "Permission denied" exit 126), `/usr/src` (source bundles),
  and builder arg paths (scripts at `/tmp/build-*.sh`, `/usr/src/*/build-*.sh`)
- Fix: added `/bin`, `/usr/bin`, `/usr/src` to SYSTEM_READ_ONLY_PATHS; scan
  `drv.arguments` and `drv.environment` for absolute paths, add as read-only
- Code: `snix-redox/src/build_proxy/allow_list.rs` — `build_allow_list()`
- 38 unit tests pass (7 new tests covering args/env scanning)

## Standalone .ion File Gotchas (test script split)

### Heredoc terminators must be at column 0 in standalone files
- In the monolithic Nix `''` string, indentation stripping moved `  FLAKEEOF` → `FLAKEEOF`
- Standalone files via `builtins.readFile` + `${content}` interpolation preserve original indentation
- Lines from `${content}` paste at column 0 — no re-indentation applied by Nix
- All heredoc terminators (FLAKEEOF, LOCKEOF, NIXEOF) need column 0 in .ion files

### Ion parses ${...} inside single quotes — syntax error on / and :
- `bash -c '... ${line//$old/$new} ...'` — Ion sees `${line//` and errors on `/`
- `bash -c '... ${HASH:0:16} ...'` — same issue with `:` inside `${}`
- Fix: write bash content to a .sh file and execute it, so Ion never parses it
- `echo 'line' >> /tmp/script.sh` then `/nix/system/profile/bin/bash /tmp/script.sh`

### bootPackages must not unconditionally include userutils
- `pkgs ? userutils` is always true (mkFlatPkgs puts it in the set)
- Must also check `inSystemPackages pkgs.userutils` (profile actually uses it)
- Without this gate, `userutilsInstalled=true` everywhere → getty runs → test scripts never execute

## Ion Shell Gotchas (keep forgetting)

### `$()` crashes on empty output
- `let var = $(grep ...)` → "Variable '' does not exist" when grep returns nothing.
- Use file-based or exit-code-based testing instead.

### `tail` does not exist on Redox
- Use `cat` or `head` (from extrautils) instead.

### Cargo build pipe exit codes lost
- `cargo build 2>&1 | while read` always exits 0 (pipe breaks).
- Use file redirection + `wait $PID` to get real exit code.
