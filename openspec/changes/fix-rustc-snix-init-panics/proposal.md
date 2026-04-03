## Why

After fixing the unwind stub linkage (fix-relibc-panic-abort), dynamically-linked Rust binaries no longer hang with "failed to initiate panic, error 0". But `rustc --print cfg` still exits 1 (LLVM init panic), `cargo build` fails (rustc subprocess invocations fail), and `snix` exits 134 (abort on init). The self-hosting test suite gets 24/76 passes — all filesystem existence checks — because no compilation or build command actually works. The nix-self-hosting-roadmap tasks (flake-build, cc-dep-build, workspace-build, source-rebuild) are blocked until these init panics are resolved.

## What Changes

- **Diagnose rustc LLVM initialization panic**: `rustc --emit=obj` (codegen) works, but `rustc --print cfg` (target query through LLVM option parsing) exits 1. Something in the LLVM session init path panics — likely `available_parallelism()` (even with `RAYON_NUM_THREADS=4` set), an unimplemented sysconf, or a missing `/proc` or `/sys` path that LLVM probes. Capture the actual panic message and backtrace.
- **Diagnose snix initialization abort**: snix is compiled with `panic=abort`, so any panic during init hits `abort()` → `_exit(134)` immediately. Need to identify which init code path panics — could be Nix evaluator setup, store path resolution, or a relibc function returning an unexpected error.
- **Fix the root causes**: Apply targeted fixes — likely environment variable settings, relibc patches for unimplemented syscalls, or LLVM option flags to skip problematic probes.
- **Restore compilation tests**: Once rustc and snix init work, `cargo build`, `snix build --expr`, and the two-step compile tests should pass, bringing the self-hosting suite from 24 to 50+ passes.

## Capabilities

### New Capabilities
- `rustc-snix-init-fix`: Diagnosis and fixes for rustc LLVM initialization panics and snix startup abort that prevent compilation on the self-hosting image

### Modified Capabilities
- `nix-derivation-builds`: Unblocked once snix and rustc init work — all on-guest build paths depend on these binaries starting successfully

## Impact

- **Self-hosting environment** (`nix/redox-system/profiles/self-hosting.nix`, `self-hosting-test.nix`): Environment variable additions or profile changes
- **relibc patches** (`nix/pkgs/system/patches/relibc/`): Possible new patches for unimplemented syscalls hit during init
- **Cross-build flags** (`nix/lib/redox-buildRustCrate.nix`): Possible rustc flag changes
- **snix source** (`nix/pkgs/userspace/snix/`): Possible init-path fixes or feature gates for Redox
- **50+ self-hosting tests**: Blocked on this fix, will unblock on resolution
