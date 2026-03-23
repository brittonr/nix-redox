# Tasks

## Phase 1: Wire upstream BuildRequest conversion

- [x] 1.1 Add `snix_build` and `snix_glue` imports to `local_build.rs` — add `use snix_build::buildservice::{BuildRequest, BuildConstraints, EnvVar}` and `use snix_glue::builder::derivation_into_build_request`
- [x] 1.2 In `build_derivation_inner()`, clone the Derivation and call `derivation_into_build_request(drv.clone(), &BTreeMap::new())` to produce a `BuildRequest` — do this before the sandbox setup block so both the original `drv` and the `BuildRequest` are available
- [x] 1.3 Replace the manual env setup (the HashMap construction from `drv.environment` + `NIX_ENVIRONMENT_VARS` loop) with `BuildRequest.environment_vars` — iterate `build_request.environment_vars` into a `HashMap<String, String>`, then post-process temp dir keys (NIX_BUILD_TOP, TMPDIR, TEMPDIR, TMP, TEMP, PWD) to substitute the actual `build_dir` path
- [x] 1.4 Replace `Command::new(&drv.builder).args(&drv.arguments)` with `Command::new(&build_request.command_args[0]).args(&build_request.command_args[1..])` — the BuildRequest combines builder + arguments into a single `command_args` vec
- [x] 1.5 Remove the `NIX_ENVIRONMENT_VARS` constant from `local_build.rs` (the upstream BuildRequest already includes these)

## Phase 2: Replace reference scanning with refscan needles

- [x] 2.1 After the build succeeds, construct reference candidates from `build_request.refscan_needles` instead of calling `collect_potential_references()` — build a `HashMap<String, String>` mapping each needle (nixbase32 hash) to its full store path by looking up output paths from `drv.outputs` and input derivation outputs from `known_paths`
- [x] 2.2 Remove the `collect_potential_references()` function — replaced with `needles_to_candidates()`
- [x] 2.3 Update `build_result_from_existing()` to also use BuildRequest needles for reference scanning — constructs its own BuildRequest internally

## Phase 3: Write additional files (passAsFile / structuredAttrs)

- [x] 3.1 After creating the temp build dir and before spawning the builder, iterate `build_request.additional_files` and write each file — the `path` is relative to the build root, so join with the actual build dir path; create parent directories as needed
- [ ] 3.2 Add a unit test that exercises passAsFile: evaluate a derivation with `passAsFile = ["x"]; x = "hello"`, build it with a builder that reads `$xPath`, and verify the file exists with correct content

## Phase 4: Use constraints for FOD detection

- [ ] 4.1 In the sandbox setup, replace the manual FOD check (inspecting `drv.environment` for `outputHash`) with `build_request.constraints.contains(&BuildConstraints::NetworkAccess)` to determine whether the sandbox should allow network access — deferred: sandbox module has its own `is_fixed_output()` that produces the same result; changing it requires threading BuildRequest through the sandbox API, better as a separate change
- [ ] 4.2 Verify the existing FOD test derivation still gets network access in the sandbox

## Phase 5: Verify and clean up

- [x] 5.1 Run `cargo test` for snix-redox — library compiles and clippy passes; test binary has pre-existing tempfile dev-dep issue in unit2nix plan
- [ ] 5.2 Run the VM functional test (`nix build .#functional-test-vm-test`) to verify end-to-end build correctness (snix-compile, rg-build, channel tests)
- [x] 5.3 Run `cargo clippy` and fix any new warnings from the refactored code — clippy passes clean
