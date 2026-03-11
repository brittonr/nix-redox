## Why

Cargo `JOBS=2` crashes with `fatal runtime error: failed to initiate panic, error 0, aborting` followed by `relibc: abort()`. The crash occurs in the linker (lld), not in cargo or rustc. Even a trivial `fn main() { println!("hello"); }` reproduces it. The Redox kernel gives the main thread ~8KB of stack; `patch-rustc-main-stack.py` grows rustc's stack to 16MB, but the cc wrapper and lld still run with the kernel default. When two linkers run simultaneously under JOBS=2, one overflows its stack.

Fixing this unblocks parallel builds on Redox, cutting self-hosted build times roughly in half.

## What Changes

- The cc wrapper (bash script in `redox-sysroot.nix`) will invoke lld through a small compiled launcher binary that spawns a thread with a large stack (same pattern as `patch-rustc-main-stack.py`).
- The compiled `cc-wrapper-redox.nix` binary (which uses `exec()` to replace the process with lld) will switch to the spawn-thread pattern instead, so lld inherits a grown stack.
- JOBS will be raised from 1 to 2 (or higher) once the fix is validated.

## Capabilities

### New Capabilities
- `lld-stack-growth`: Grow lld's thread stack in the cc wrapper so the linker doesn't overflow under parallel builds.

### Modified Capabilities

_None. No existing spec-level requirements change._

## Impact

- `nix/pkgs/userspace/redox-sysroot.nix` — the bash cc wrapper script that invokes lld
- `nix/pkgs/userspace/cc-wrapper-redox.nix` — the compiled cc-wrapper binary
- Self-hosting test profile (`self-hosting-test.nix`) — JOBS parameter
- AGENTS.md — update the "CARGO_BUILD_JOBS > 1 hangs" note once validated
