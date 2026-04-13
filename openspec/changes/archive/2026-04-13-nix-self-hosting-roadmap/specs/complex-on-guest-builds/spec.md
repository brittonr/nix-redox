## MODIFIED Requirements

### Requirement: C-dependency crate builds through snix on guest
snix SHALL build a Rust crate whose `build.rs` uses cc-rs to compile C source code via the CC wrapper. The sandbox SHALL allow the build script to invoke the CC wrapper (`/nix/system/profile/bin/cc`), which in turn invokes clang and lld from the system profile.

This requirement is validated by the VM test suite, not just host-side unit tests. The sandbox allow-list, CC wrapper resolution, and sysroot header access SHALL all work under the real Redox kernel's scheme-based filesystem.

#### Scenario: Build a crate with cc-rs C compilation on guest
- **WHEN** `snix build --file /usr/src/cc-dep-test/build.nix` is run on the guest
- **THEN** the build succeeds and produces an executable in `/nix/store/`
- **AND** the executable runs and prints output from the C function

#### Scenario: CC wrapper resolves clang and lld in sandbox
- **WHEN** a cc-rs build script runs inside the per-path sandbox on the guest
- **THEN** the CC wrapper at `/nix/system/profile/bin/cc` is accessible
- **AND** clang and lld are accessible through the sandbox allow-list
- **AND** sysroot headers at `/usr/lib/redox-sysroot/sysroot/include/` are accessible

### Requirement: Cargo workspace crate builds through snix on guest
snix SHALL build a Cargo workspace containing multiple crates (at least one library and one binary) where the binary depends on the library via path dependency. Validated on the real guest.

#### Scenario: Build a two-crate workspace on guest
- **WHEN** `snix build --file /usr/src/workspace-test/build.nix` is run on the guest
- **THEN** the build succeeds and produces the binary executable in `/nix/store/`
- **AND** the executable runs and prints output proving the lib dependency was linked
