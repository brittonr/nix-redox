## ADDED Requirements

### Requirement: 4-gaps code passes on real Redox guest
The self-hosting test suite SHALL exercise fetchGit, flake installable builds, C-dependency crate builds, workspace builds, and source-based rebuild on a running Redox VM. Each code path SHALL emit a FUNC_TEST verdict. All five paths SHALL pass before subsequent roadmap work begins.

#### Scenario: fetchGit builds a derivation from a git source
- **WHEN** the self-hosting test runs the fetchGit test phase
- **AND** the guest evaluates a Nix expression using `builtins.fetchGit` with a local bare repo
- **THEN** the evaluation produces a store path containing the fetched source
- **AND** the test emits `FUNC_TEST:fetchgit:PASS`

#### Scenario: Flake installable builds produce store output
- **WHEN** the self-hosting test runs `snix build /usr/src/test-flake#hello`
- **THEN** the output path in `/nix/store/` contains `bin/hello`
- **AND** executing the binary prints `Hello from flake!`
- **AND** the test emits `FUNC_TEST:flake-build:PASS`

#### Scenario: C-dependency crate compiles through snix
- **WHEN** the self-hosting test runs `snix build --file /usr/src/cc-dep-test/build.nix`
- **AND** the crate's build.rs uses cc-rs to compile C source
- **THEN** the output binary runs and prints output from the C function
- **AND** the test emits `FUNC_TEST:cc-dep-build:PASS`

#### Scenario: Workspace crate builds through snix
- **WHEN** the self-hosting test runs `snix build --file /usr/src/workspace-test/build.nix`
- **AND** the workspace contains a lib crate and a bin crate with a path dependency
- **THEN** the output binary runs and prints output proving the lib was linked
- **AND** the test emits `FUNC_TEST:workspace-build:PASS`

#### Scenario: Source-based rebuild applies configuration
- **WHEN** the self-hosting test runs `snix system rebuild --source --dry-run`
- **AND** a `packageSources` .nix file is present in the config
- **THEN** the command lists derivations that would be built without executing them
- **AND** the test emits `FUNC_TEST:source-rebuild-dryrun:PASS`

### Requirement: VM validation failures produce actionable diagnostics
When a 4-gaps test phase fails on the guest, the test script SHALL capture the snix stderr output, the last 20 lines of build log (if available), and the exit code, and include them in the FUNC_TEST:name:FAIL:reason verdict.

#### Scenario: Build failure captures log context
- **WHEN** `snix build --file /usr/src/cc-dep-test/build.nix` exits non-zero
- **THEN** the test emits `FUNC_TEST:cc-dep-build:FAIL:<exit_code>:<last_lines_of_stderr>`
