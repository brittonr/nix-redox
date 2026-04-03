## MODIFIED Requirements

### Requirement: snix-compile goes through snix build
The snix self-compile test SHALL invoke `snix build --file /usr/src/snix-redox/build.nix` instead of running `cargo build --offline` directly. The builder script (`build-snix.sh`) SHALL be pre-installed in the snix source bundle. The compiled snix binary SHALL be produced in a `/nix/store/` output path. The build execution SHALL use upstream `derivation_into_build_request()` for environment setup, with temp dir paths substituted to the actual build directory.

Additionally, the local builder SHALL handle derivations whose build scripts invoke the CC wrapper to compile C source code via clang. The per-path sandbox SHALL grant read-only access to system profile tool paths (`/nix/system/profile/bin/cc`, `clang`, `ld.lld`) and sysroot headers (`/usr/lib/redox-sysroot/`). The sandbox SHALL allow build scripts to create and link against static C libraries produced by cc-rs.

#### Scenario: snix self-compile via snix build
- **WHEN** the self-hosting test reaches the snix-compile phase
- **THEN** it runs `snix build --file /usr/src/snix-redox/build.nix` and the output path contains a working `snix` binary at `$out/bin/snix`

#### Scenario: snix-compile PASS verdict
- **WHEN** `snix build` succeeds and the output binary runs `--version` without error
- **THEN** the test emits `FUNC_TEST:snix-compile:PASS`

#### Scenario: snix-compile FAIL on build failure
- **WHEN** `snix build` exits non-zero or the output binary is missing
- **THEN** the test emits `FUNC_TEST:snix-compile:FAIL:<reason>` with build log context

#### Scenario: Build with cc-rs invocation succeeds in sandbox
- **WHEN** a derivation's builder runs `cargo build` on a crate with a cc-rs build script
- **AND** the build script calls `cc::Build::new().file("src/foo.c").compile("foo")`
- **THEN** the CC wrapper is invoked, clang compiles the C file, and the resulting `.a` is linked into the binary
- **AND** the sandbox does not block access to clang, lld, or sysroot headers

## ADDED Requirements

### Requirement: Workspace crate builds complete without deadlock
The local builder SHALL build Cargo workspace projects containing multiple crates with inter-crate path dependencies. The builder SHALL set `CARGO_BUILD_JOBS` and `CARGO_INCREMENTAL=0` to prevent fingerprint instability.

#### Scenario: Two-crate workspace builds and links
- **WHEN** a derivation builds a workspace with `members = ["mylib", "mybin"]` and `mybin` depends on `mylib`
- **THEN** cargo compiles both crates and produces the `mybin` binary in the output

#### Scenario: Workspace build respects JOBS setting
- **WHEN** `CARGO_BUILD_JOBS=2` is set in the derivation environment
- **THEN** cargo schedules up to 2 parallel compilation units
- **AND** the build completes within the timeout (no deadlock)
