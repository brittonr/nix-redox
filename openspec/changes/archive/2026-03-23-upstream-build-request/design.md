## Context

`local_build.rs` builds derivations by: (1) extracting env vars from the Derivation struct, (2) layering on NIX_ENVIRONMENT_VARS with temp dir substitutions, (3) spawning the builder with those env vars, (4) collecting reference candidates from input derivations, (5) scanning outputs for references. Steps 1-2 and 4 duplicate logic that upstream's `snix_glue::builder::derivation_into_build_request()` already provides in a tested, maintained form.

Upstream's function produces a `BuildRequest` with fully resolved `environment_vars`, `command_args`, `outputs`, `refscan_needles`, `constraints`, and `additional_files`. Our code currently ignores all of this — we use `DummyBuildService` during eval and then re-derive everything from the raw Derivation.

## Goals / Non-Goals

**Goals:**
- Use `derivation_into_build_request()` to produce environment variables, command args, output paths, refscan needles, and additional files
- Remove our duplicate `NIX_ENVIRONMENT_VARS` constant
- Remove `collect_potential_references()` (replaced by `refscan_needles`)
- Gain passAsFile and structuredAttrs support (upstream handles both)
- Use `BuildRequest.constraints` to determine FOD network access instead of manual output hash checking
- Keep the public API of `build_derivation()` and `build_needed()` unchanged

**Non-Goals:**
- Implementing the `BuildService` trait (future change)
- Replacing our PathInfoDb or NAR hashing
- Changing the sandbox or process spawning logic
- Changing dependency resolution / topological sort

## Decisions

### Consume BuildRequest in build_derivation_inner

Split `build_derivation_inner` into two phases:
1. **Conversion**: call `derivation_into_build_request(drv, &inputs)` to get a `BuildRequest`
2. **Execution**: a new internal function takes the `BuildRequest` plus Redox-specific context (sandbox config, PathInfoDb) and runs the build

The `inputs` parameter for `derivation_into_build_request` needs `BTreeMap<StorePath, Node>`. Since we don't have castore Nodes (we use filesystem paths directly), we pass an empty map. The function still produces correct env vars, command args, and refscan needles — the `inputs` field only matters for content-addressed input propagation which we don't use yet.

**Alternative**: Extract only specific fields (env vars, refscan needles) from BuildRequest. Rejected because partial adoption creates a maintenance seam — we'd have some fields from BuildRequest and others hand-rolled.

### Temp dir substitution after BuildRequest conversion

BuildRequest uses "/build" for all temp dirs (NIX_BUILD_TOP, TMPDIR, etc.) because upstream assumes a container with a chroot. We run on the real filesystem, so after getting the BuildRequest, we post-process `environment_vars` to replace "/build" with the actual temp build directory path. This is a small fixup over a correct base, rather than reimplementing the entire env setup.

### Refscan needles replace collect_potential_references

BuildRequest's `refscan_needles` contains nixbase32 hashes of all output paths and input paths. Our `collect_potential_references()` manually builds this same set by iterating `drv.input_derivations` and `drv.outputs`. The upstream version is more complete (includes `input_sources` and uses the same ordering as upstream Nix).

Our `scan_references()` function currently takes full store path strings as candidates. We'll adapt it to accept nixbase32 hash needles from BuildRequest, then map matched needles back to full store paths using KnownPaths.

### Additional files for passAsFile / structuredAttrs

BuildRequest's `additional_files` contains files that should be written into the build directory before execution. Our current code doesn't handle passAsFile or structuredAttrs at all. After creating the temp build dir, we write each additional file before spawning the builder. File paths in `additional_files` are relative to the build root — we prefix with the actual temp dir path.

### Keep Derivation available alongside BuildRequest

The sandbox setup still needs the raw Derivation (for `sandbox::config_from_derivation()` and `build_proxy::build_allow_list()`). Rather than refactoring the sandbox code in this change, we keep both the Derivation and the BuildRequest available during build execution.

## Risks / Trade-offs

**[Empty inputs map]** Passing empty inputs to `derivation_into_build_request` means we don't get castore Node entries in the BuildRequest. This is fine today (we don't use content-addressed inputs) but will need fixing when we adopt PathInfoService. → No mitigation needed now; tracked for future BuildService change.

**[Temp dir fixup fragility]** If upstream adds new temp-dir-related env vars, our fixup loop won't catch them. → The fixup explicitly lists the known keys (NIX_BUILD_TOP, TMPDIR, TEMPDIR, TMP, TEMP, PWD) matching the upstream constant. If upstream changes the constant, we'll see it during the next pin bump.

**[Derivation consumed by conversion]** `derivation_into_build_request` takes ownership of the Derivation (moves it). The sandbox setup needs the Derivation too. → Clone the Derivation before conversion, or restructure to extract sandbox config first.
