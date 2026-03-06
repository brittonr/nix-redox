## Why

Cargo build scripts with `println!` hang on Redox OS — the stdout pipe from the build-script process back to cargo never delivers data. Root cause: relibc's `chdir()` deadlocks on the CWD `RwLock` when the path is relative. After `fork()`, the child calls `chdir()` (from `Command::current_dir()`), acquires a write lock on CWD, then internally calls `current_dir()` which tries to acquire a read lock on the same CWD — deadlock. Our CLOEXEC pipe skip patch means the parent never learns the child is stuck, so cargo blocks on an empty pipe forever.

This is the last blocker for real-world Rust crate compilation on Redox (any crate with a `build.rs` — serde, tokio, regex, etc.).

## What Changes

- Backport the one-line fix from upstream relibc commit `9cde64a3`: change `current_dir()?` to `cwd_guard` in `chdir()` so the already-held write guard is reused instead of attempting a second lock acquisition.
- Add a new Python patch script (`patch-relibc-chdir-deadlock.py`) applied during relibc's `patchPhase`.
- Update the self-hosting test suite: convert the build-script test (Step 10) from a known-fail skip to an actual cargo build with `build.rs` that must pass.

## Capabilities

### New Capabilities
- `chdir-deadlock-fix`: Backport of upstream relibc chdir deadlock fix via a surgical Python patch, plus test validation.

### Modified Capabilities

## Impact

- `nix/pkgs/system/relibc.nix` — adds new patch script to `patchPhase`
- `nix/pkgs/system/patch-relibc-chdir-deadlock.py` — new file
- `nix/redox-system/profiles/self-hosting-test.nix` — Step 10 changes from skip to real test
- Rebuild cascade: relibc → sysroot → all cross-compiled packages → disk images
- No API changes; no vendor hash changes; no flake input changes
