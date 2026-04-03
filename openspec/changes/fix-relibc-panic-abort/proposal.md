## Why

Every dynamically-linked binary on the self-hosting Redox image aborts immediately with `"fatal runtime error: failed to initiate panic, error 0, aborting"` followed by `"relibc: abort() called"`. This kills the entire self-hosting test suite — rustc, cargo, snix, and all on-guest builds fail with exit code 134 (SIGABRT). The 76-test self-hosting suite completes in 24 seconds instead of the expected 15+ minutes because nothing actually runs. No on-guest compilation or Nix builds can be validated until this is fixed.

## What Changes

- **Diagnose the panic initiation failure**: Determine why the Rust panic runtime (`libpanic_abort`) cannot initiate a panic. The error `"failed to initiate panic, error 0"` comes from `std::panicking::rust_panic_with_hook` when `__rust_start_panic` returns an error. With `-C panic=abort`, this should call `intrinsics::abort()` directly, but the "failed to initiate" path means the panic infrastructure is entered before the abort handler runs. Something in the DSO init chain, the rlib linkage, or the `panic_abort` crate's integration with relibc is broken.
- **Fix the root cause**: Likely one of: (a) mismatched `libpanic_abort` rlib between cross-toolchain and on-image sysroot, (b) relibc's `abort()` or signal handling interfering with the panic runtime, (c) a regression in the `patch-relibc-abort-dso.patch` that changed abort() to `_exit(134)`, (d) DSO initialization order leaving the panic handler unregistered, or (e) stack/memory corruption during ld_so startup preventing panic machinery from working.
- **Restore self-hosting test suite to passing state**: Once the abort is fixed, the existing 50+ compilation tests (cargo build, snix build, rustc invocations) should resume working, and the new nix-self-hosting-next tests (flake installable, cc-dep, workspace, source rebuild) can be validated.

## Capabilities

### New Capabilities
- `panic-abort-fix`: Diagnosis and fix for the `"failed to initiate panic"` abort that prevents all dynamically-linked Rust binaries from running on the self-hosting image

### Modified Capabilities
- `dso-environ-propagation`: May need changes if the panic handler registration depends on DSO init ordering
- `nix-derivation-builds`: Unblocked once the abort is fixed — the local builder, sandbox, and all on-guest build paths depend on working binaries

## Impact

- **relibc patches** (`nix/pkgs/system/patches/relibc/`): Likely patch changes — `patch-relibc-abort-dso.patch`, possibly `patch-relibc-run-init.patch` or `patch-relibc-grow-main-stack.patch`
- **Sysroot assembly** (`nix/lib/sysroot.nix`): May need rlib version alignment between cross-toolchain and on-image sysroot
- **Cross-build flags** (`nix/lib/redox-buildRustCrate.nix`): Uses `-C panic=abort` — may need verification against toolchain rlib hashes
- **Self-hosting test suite** (`nix/redox-system/profiles/self-hosting-test.nix`): 50+ tests blocked, will unblock on fix
- **All cross-compiled Rust packages**: Every package in the system (snix, ion, uutils, extrautils, etc.) is affected since all are built with `panic=abort`
