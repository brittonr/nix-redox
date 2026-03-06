## ADDED Requirements

### Requirement: chdir with relative path must not deadlock
The relibc `chdir()` function SHALL NOT attempt to re-acquire the CWD RwLock when it already holds a write lock. When `chdir()` needs to resolve a relative path, it MUST use the already-held write guard to access the current working directory fd, not call `current_dir()`.

#### Scenario: Child process chdir during Command::spawn
- **WHEN** a Rust program calls `Command::new("binary").current_dir("/some/path").spawn()` and the child process executes `chdir()` before `exec()`
- **THEN** the child process SHALL complete the `chdir()` call without deadlocking, regardless of whether the path is relative or absolute

#### Scenario: Cargo build script with println directives
- **WHEN** `cargo build` is run on a project with a `build.rs` that calls `println!("cargo:rustc-cfg=has_feature")` and `println!("cargo:rustc-env=KEY=value")`
- **THEN** cargo SHALL read the build script's stdout, process the directives, and compile `src/main.rs` with the cfg and env values applied
- **AND** the resulting binary SHALL execute successfully with the build-script-injected values accessible

### Requirement: Patch applied during relibc build
The chdir deadlock fix SHALL be applied as a Python patch script during relibc's `patchPhase`, following the existing `patch-relibc-*.py` convention. The patch MUST fail the build if the target source text is not found (indicating the relibc pin has changed).

#### Scenario: Patch applies to pinned relibc
- **WHEN** relibc is built from the pinned source (`28ffabebf629`, Feb 19 2026)
- **THEN** `patch-relibc-chdir-deadlock.py` SHALL find the exact target text in `src/platform/redox/path.rs` and replace it successfully

#### Scenario: Patch fails on updated relibc
- **WHEN** relibc source is updated to a commit that already includes the upstream fix (`9cde64a3` or later)
- **THEN** `patch-relibc-chdir-deadlock.py` SHALL exit with a non-zero status, failing the build, signaling the patch should be removed

### Requirement: Self-hosting test validates build scripts
The self-hosting test suite's Step 10 (cargo build with build.rs) SHALL attempt a real cargo build of a project containing a `build.rs` with `println!` directives, instead of skipping with a known-fail marker.

#### Scenario: Build script test passes
- **WHEN** the self-hosting test VM runs Step 10
- **THEN** cargo SHALL compile the build script, execute it, read its `cargo:rustc-cfg` and `cargo:rustc-env` directives, compile the main binary with those values, and the test SHALL report `FUNC_TEST:cargo-buildrs:PASS`

#### Scenario: Build script test fails
- **WHEN** the build script hangs or cargo fails during Step 10
- **THEN** the test SHALL time out and report `FUNC_TEST:cargo-buildrs:FAIL` with diagnostic information
