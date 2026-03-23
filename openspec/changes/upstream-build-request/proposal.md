## Why

Our `local_build.rs` duplicates upstream snix-glue's `derivation_into_build_request()` logic — environment variable setup, `NIX_ENVIRONMENT_VARS`, placeholder replacement, output path marshaling, and refscan needle computation are all hand-rolled. This duplication means we miss features upstream already handles (passAsFile, structuredAttrs) and creates drift risk as upstream evolves. The previous changes (refscan, tar, env vars) already reduced our custom surface; this continues that trajectory by adopting the upstream `Derivation → BuildRequest` conversion.

## What Changes

- Refactor `build_derivation_inner()` to accept a `BuildRequest` from upstream's `derivation_into_build_request()` instead of constructing env/args/outputs from raw `Derivation` fields
- Replace our `NIX_ENVIRONMENT_VARS` constant and manual env setup with BuildRequest's `environment_vars`
- Replace `collect_potential_references()` with BuildRequest's `refscan_needles` for reference scanning
- Use BuildRequest's `command_args` instead of manually combining `drv.builder` + `drv.arguments`
- Use BuildRequest's `outputs` for output path verification instead of iterating `drv.outputs`
- Use BuildRequest's `constraints` to determine sandbox behavior (NetworkAccess for FODs)
- Write BuildRequest's `additional_files` into the build directory (enables passAsFile and structuredAttrs)
- Keep all Redox-specific code unchanged: sandbox namespace setup, per-path proxy, process spawning, pipe draining, output verification via raw SYS_OPENAT, NAR hashing, PathInfo registration

## Capabilities

### New Capabilities
- `upstream-build-request`: Use upstream snix-glue's BuildRequest conversion in local_build.rs

### Modified Capabilities
- `nix-derivation-builds`: Build execution now consumes BuildRequest instead of raw Derivation for env/args/output setup

## Impact

- `snix-redox/src/local_build.rs` — major refactor of `build_derivation_inner()` internals; public API unchanged
- `snix-redox/src/local_build.rs` — `NIX_ENVIRONMENT_VARS` constant removed (use upstream's)
- `snix-redox/src/local_build.rs` — `collect_potential_references()` removed or simplified
- Existing tests must still pass — same build semantics, different internal code path
- VM functional tests validate end-to-end correctness
