## Context

Relibc (Redox's C library) manages the process working directory via a global `CWD: RwLock<Option<Cwd>>`. The `chdir()` function acquires a **write** lock, then on relative paths calls `current_dir()` which tries to acquire a **read** lock — classic self-deadlock on a non-reentrant RwLock.

This deadlock is triggered during `Command::spawn()` when the child process executes `chdir()` before `exec()`. Combined with our CLOEXEC pipe skip patch (`patch-rustc-spawn-pipes.py`), the parent never detects the child hung, so cargo blocks forever on an empty stdout pipe.

Upstream fixed this in commit `9cde64a3` (Mar 01 2026) — a one-line change replacing `current_dir()?` with the already-held `cwd_guard`. Our relibc is pinned to `28ffabebf629` (Feb 19 2026).

## Goals / Non-Goals

**Goals:**
- Fix the chdir deadlock so cargo build scripts can execute on Redox
- Minimal, surgical patch that doesn't disturb the rest of relibc
- Validate with an actual cargo-build-with-build.rs test (not a skip)

**Non-Goals:**
- Full relibc pin bump (would pull in ~40 commits with API changes, vendor hash churn, and potential conflicts with our 4 existing patches)
- Fixing the upstream kernel pipe WaitCondition issues (`437f7623`) — those are secondary improvements
- Removing our existing CLOEXEC/read2/linker pipe patches (still needed for other code paths)

## Decisions

**1. Python patch script (not sed, not full pin bump)**

The patch targets one function (`chdir`) in one file (`src/platform/redox/path.rs`). A Python script with exact string matching follows the established pattern (`patch-relibc-*.py`). Alternatives:
- *sed*: fragile for multi-line context matching
- *Pin bump*: pulls `cab00214` (protocol refactor) which breaks our `patch-relibc-ns-fd.py` and changes vendor hashes across the board
- *Nix patch file*: would work, but the project convention is Python scripts

**2. Test update: convert skip to real test**

Step 10 in `self-hosting-test.nix` currently skips the build-script test with `echo "pipe-hang"`. After the fix, this should attempt a real `cargo build` of a project with `build.rs` that uses `println!("cargo:rustc-cfg=...")` and `println!("cargo:rustc-env=...")`. The test passes if the binary runs and the build-script-injected cfg/env are present.

**3. Keep existing pipe patches**

The CLOEXEC skip, read2 sequential, and linker inherit patches address separate issues (poll crash, CLOEXEC pipe crash). They remain necessary even after the chdir fix.

## Risks / Trade-offs

**[Risk: Patch doesn't match source]** → The patch uses exact string matching against the Feb 19 relibc source. If someone updates the relibc pin without removing this patch, it will fail loudly (Python `sys.exit(1)` on mismatch). This is the correct behavior — a pin bump should integrate the upstream fix directly.

**[Risk: chdir isn't the only deadlock]** → The `current_dir()` function is called from other places too (e.g., `open()`, `openat2_path()`). The upstream `3385c66c` commit reworks all `*at` functions. Our patch only fixes `chdir()` — if cargo hits the deadlock through a different `current_dir()` call site, we'd need a broader backport. Mitigation: the test will tell us immediately.

**[Risk: Relative vs absolute path]** → The deadlock only triggers on relative paths in `chdir()`. Cargo typically uses absolute paths for build directories. If cargo happens to use absolute paths on Redox, this patch might not be the fix and the real issue is elsewhere. Mitigation: the test either passes or it doesn't — no ambiguity.
