## ADDED Requirements

### Requirement: C-dependency crate builds through snix on guest
snix SHALL build a Rust crate whose `build.rs` uses cc-rs to compile C source code via the CC wrapper. The sandbox SHALL allow the build script to invoke the CC wrapper (`/nix/system/profile/bin/cc`), which in turn invokes clang and lld from the system profile.

#### Scenario: Build a crate with cc-rs C compilation
- **WHEN** a Nix derivation builds a Rust crate with `build.rs` containing `cc::Build::new().file("src/hello.c").compile("hello")`
- **AND** the crate's Rust code calls the compiled C function via FFI
- **AND** `snix build --file /usr/src/cc-dep-test/build.nix` is run on the guest
- **THEN** the build succeeds and produces an executable in `/nix/store/`
- **AND** the executable runs and prints output from the C function

#### Scenario: CC wrapper resolves clang and lld in sandbox
- **WHEN** a cc-rs build script runs inside the per-path sandbox
- **THEN** the CC wrapper at `/nix/system/profile/bin/cc` is accessible (read-only)
- **AND** clang at `/nix/system/profile/bin/clang` is accessible (read-only)
- **AND** lld at `/nix/system/profile/bin/ld.lld` is accessible (read-only)
- **AND** sysroot headers at `/usr/lib/redox-sysroot/sysroot/include/` are accessible (read-only)

### Requirement: Cargo workspace crate builds through snix on guest
snix SHALL build a Cargo workspace containing multiple crates (at least one library and one binary) where the binary depends on the library via path dependency.

#### Scenario: Build a two-crate workspace
- **WHEN** a Nix derivation builds a Cargo workspace with `members = ["mylib", "mybin"]`
- **AND** `mybin` depends on `mylib` via `path = "../mylib"`
- **AND** `snix build --file /usr/src/workspace-test/build.nix` is run on the guest
- **THEN** the build succeeds and produces `mybin` executable in `/nix/store/`
- **AND** the executable runs and prints output proving the lib dependency was linked

#### Scenario: Workspace build with JOBS=2
- **WHEN** the workspace build runs with `CARGO_BUILD_JOBS=2`
- **THEN** cargo compiles the lib and bin crates (potentially in parallel)
- **AND** the build completes without deadlock or timeout

### Requirement: Test bundles ship on disk image
The build system SHALL produce `cc-dep-test-bundle` and `workspace-test-bundle` derivations containing the test sources and `build.nix` files. The self-hosting test profile SHALL include them at `/usr/src/cc-dep-test/` and `/usr/src/workspace-test/`.

#### Scenario: C-dep test bundle present
- **WHEN** the self-hosting-test VM boots
- **THEN** `/usr/src/cc-dep-test/build.nix` exists
- **AND** `/usr/src/cc-dep-test/src/hello.c` exists

#### Scenario: Workspace test bundle present
- **WHEN** the self-hosting-test VM boots
- **THEN** `/usr/src/workspace-test/build.nix` exists
- **AND** `/usr/src/workspace-test/mylib/src/lib.rs` exists
- **AND** `/usr/src/workspace-test/mybin/src/main.rs` exists
