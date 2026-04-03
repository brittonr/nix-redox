## Context

The self-hosting Redox image boots and runs Ion (statically linked), but every dynamically-linked Rust binary aborts immediately. The error sequence is:

```
fatal runtime error: failed to initiate panic, error 0, aborting
relibc: abort() called
```

This affects rustc, cargo, snix, and all Rust binaries cross-compiled with `-C panic=abort` and linked against relibc. The error originates from `std::panicking::rust_panic_with_hook` — the panic runtime is entered, but `__rust_start_panic` fails before it can do anything.

Key facts from the build system:
- All userspace Rust crates are compiled with `-C panic=abort` (`redox-buildRustCrate.nix:155`)
- The toolchain ships both `libpanic_abort-*.rlib` and `libpanic_unwind-*.rlib`
- The sysroot on the image is assembled from `rust-std-1.92.0-nightly-2025-10-03`
- relibc's `abort()` is patched to call `_exit(134)` instead of `ud2` (`patch-relibc-abort-dso.patch`)
- DSO-linked binaries go through `ld_so` → `relibc_start_v1` → `__relibc_init_*` symbol injection
- `rustc -vV` succeeds (simple query, no panic path exercised), but `rustc --print cfg` aborts (exercises LLVM options parsing which may trigger a panic on unsupported features)

The 25 passing tests are all filesystem existence checks. The 50 failing tests all try to execute Rust binaries that touch code paths where panics can be triggered.

## Goals / Non-Goals

**Goals:**
- Identify the exact failure mechanism: which function in the panic initiation chain fails and why
- Fix the root cause so dynamically-linked Rust binaries can run on the self-hosting image
- Restore the self-hosting test suite to its previous passing state (snix build, cargo build, rustc compilation all worked in prior images)
- Verify fix with a targeted smoke test before running the full 76-test suite

**Non-Goals:**
- Switching from `panic=abort` to `panic=unwind` — abort is correct for the embedded target
- Fixing upstream relibc bugs beyond what's needed for panic handling
- Changing the DSO loading architecture
- Adding panic=unwind support to the Redox userspace

## Decisions

### 1. Diagnostic-first approach

**Decision**: Start with binary-level diagnostics before changing code. Use `LD_DEBUG=all` tracing, `readelf` analysis of the panic rlibs, and minimal reproduction cases to narrow the failure.

**Rationale**: The error message is ambiguous — "failed to initiate panic, error 0" could come from at least 5 different points in the panic chain. Changing code without understanding the exact failure point risks introducing new issues.

**Diagnostic sequence**:
1. Check if a statically-linked Rust binary can trigger a panic path (isolate DSO vs static)
2. Compare rlib hashes between the cross-toolchain and on-image sysroot (detect version mismatch)
3. Check if `__rust_start_panic` symbol is present and correctly linked
4. Trace DSO init order with `LD_DEBUG` to see if panic handler registration happens
5. Build a minimal C program calling `abort()` to confirm relibc's abort path works independently

### 2. Suspect ranking

**Decision**: Investigate in this priority order:
1. **rlib version mismatch** — the cross-toolchain and on-image sysroot may ship different `libpanic_abort` rlibs with incompatible ABIs
2. **Stack guard page fault** — `patch-relibc-grow-main-stack.patch` or `patch-relibc-prefault-stack.patch` may interact badly with the panic runtime's stack probing
3. **DSO init ordering** — `panic_abort`'s `__rust_start_panic` may not be visible to the main binary after DSO loading
4. **relibc abort() patch interaction** — `_exit(134)` in abort() may be reached before the panic handler can run, but this is the symptom not the cause

**Rationale**: rlib mismatch is the simplest explanation and most common cause of "suddenly everything aborts" regressions. The sysroot assembly step copies rlibs from one Nix store path, but the cross-compiler may reference a different set.

### 3. Fix strategy

**Decision**: Once the root cause is identified, apply the minimal fix and validate with a 3-step test:
1. `rustc --print cfg` (the simplest command that currently aborts)
2. `rustc -o binary empty.rs` (compile + link)
3. `snix build --expr "derivation { ... }"` (the full build pipeline)

**Rationale**: These three steps cover increasing complexity. If all three pass, the full test suite should recover.

## Risks / Trade-offs

**[Sysroot rebuild cascades through all packages]** — If the fix requires a sysroot change, every cross-compiled package must be rebuilt. This is a ~45 minute full rebuild. Mitigation: verify the fix in isolation before triggering the full rebuild.

**[relibc patches may conflict with upstream changes]** — The relibc source is pinned to a specific commit. If the fix requires a relibc update, all 13 patches must be rebased. Mitigation: prefer fixes that don't change the relibc source pin.

**[The abort may mask a deeper issue]** — "failed to initiate panic" could be a symptom of memory corruption during DSO loading that coincidentally hits the panic path first. Mitigation: the diagnostic sequence includes a static binary test to rule out kernel/memory issues.
