## Why

Cargo build with `build.rs` crashes on Redox — rustc hits `ud2` (Invalid opcode) inside `abort()` in librustc_driver.so's bundled relibc. The DSO's `abort()` reads an abort-hook function pointer that resolves to a BSS-initialized zero (NULL), jumping to `ud2` instead of calling the hook. This masks the real panic that triggered abort, making debugging impossible. Fixing the abort hook initialization and the underlying panic unblocks cargo build scripts — the last missing piece for full self-hosted compilation on Redox.

## What Changes

- Patch relibc's `abort()` to handle the case where the abort hook pointer is NULL in DSOs: instead of `ud2`, call `_exit(134)` (SIGABRT equivalent) so the parent process gets a clean exit status and cargo can report the error.
- Add `/etc/hosts` to the Redox disk image (gethostent opens this file; its absence may trigger the panic).
- Add diagnostic instrumentation to the self-hosting test Step 10 to capture cargo's exact rustc arguments and the failure point.
- Investigate and fix the root panic cause once diagnostics reveal it.

## Capabilities

### New Capabilities
- `abort-dso-fix`: Patch relibc's abort() to gracefully handle uninitialized abort hook in DSOs, plus investigate and fix the underlying rustc panic during cargo build-script compilation.

### Modified Capabilities

## Impact

- `nix/pkgs/system/relibc.nix` — new patch script in patchPhase
- `nix/pkgs/system/patch-relibc-abort-dso.py` — new file
- `nix/redox-system/modules/build/` or `profiles/` — `/etc/hosts` generation
- `nix/redox-system/profiles/self-hosting-test.nix` — Step 10 diagnostics
- Rebuild cascade: relibc → sysroot → all cross-compiled packages → disk images
