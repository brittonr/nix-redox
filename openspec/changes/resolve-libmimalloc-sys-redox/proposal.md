## Why

The remaining self-hosting blocker has narrowed from a vague `snix-compile` failure to a concrete allocator build failure. A focused `snix-compile-test` rerun with durable logs reproduced the problem in about 1169 seconds and showed that the self-compiled derivation currently dies in `libmimalloc-sys` while compiling `c_src/mimalloc/v2/src/static.c` on Redox.

As long as that allocator path fails, the self-hosting baseline cannot close cleanly and full-suite reruns either fail or waste time before they reach the real blocker. We need a dedicated change that captures the current evidence, evaluates the viable fix paths, and lands the smallest Redox-safe solution.

## What Changes

- Capture the focused `libmimalloc-sys` self-compile failure as the current evidence-backed baseline for the remaining `snix-compile` blocker
- Trace how `libmimalloc-sys` enters the self-hosted `snix` dependency graph on Redox and which feature or dependency choice controls it
- Evaluate Redox-safe fix paths for the allocator build, including:
  - Redox-only feature selection that avoids `libmimalloc-sys`
  - targeted downstream patching of `libmimalloc-sys` / mimalloc if the dependency must remain
  - any minimal allocator fallback that preserves `snix` CLI behavior on Redox
- Verify the chosen fix first with the focused `snix-compile-test` runner, then with the full `self-hosting-test` suite
- Update the self-hosting documentation and evidence trail with the final root cause and chosen fix

## Capabilities

### New Capabilities

### Modified Capabilities
- `nix-derivation-builds`: the `snix-compile` self-build requirement must cover allocator-related C dependencies such as `libmimalloc-sys` and require a Redox-safe outcome

## Impact

- `snix-redox/Cargo.toml` and any allocator-related feature selection or transitive dependency wiring
- vendored/self-hosted source bundle inputs if a Redox-specific patch must be carried into guest builds
- `nix/pkgs/infrastructure/build-snix.sh`, `nix/pkgs/infrastructure/snix-source-bundle.nix`, and `nix/pkgs/infrastructure/snix-upstream-source.nix` if the chosen fix changes the self-build environment or patched upstream sources
- `nix/pkgs/userspace/patches/patch-snix-fetcher-no-tls-panic.py` if the same `snix-glue` no-CA workaround must be shared by both the packaged build and the source bundle
- focused validation harness files such as `nix/redox-system/profiles/snix-compile-test.nix` and `nix/flake-modules/system.nix`
- OpenSpec evidence and persistent repo guidance (`AGENTS.md`, `.agent/napkin.md`)
