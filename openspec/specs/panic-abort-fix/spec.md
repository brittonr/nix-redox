## ADDED Requirements

### Requirement: Dynamically-linked Rust binaries run without abort
All Rust binaries cross-compiled with `-C panic=abort` and dynamically linked against relibc SHALL execute without triggering `"fatal runtime error: failed to initiate panic"`. This applies to all binaries in the self-hosting image including rustc, cargo, snix, and user-compiled programs.

#### Scenario: rustc query commands succeed
- **WHEN** the self-hosting image boots
- **AND** the user runs `rustc --print cfg`
- **THEN** rustc prints the target configuration and exits 0
- **AND** no "fatal runtime error" appears in stderr or serial log

#### Scenario: rustc compilation succeeds
- **WHEN** the user runs `rustc -o binary source.rs` with valid Rust source
- **THEN** rustc produces an executable binary
- **AND** the binary runs and exits normally

#### Scenario: snix build executes derivations
- **WHEN** the user runs `snix build --expr "derivation { ... }"`
- **THEN** snix evaluates the expression, runs the builder, and produces output in `/nix/store/`
- **AND** snix exits 0

#### Scenario: cargo build compiles crates
- **WHEN** the user runs `cargo build` in a valid Rust project directory
- **THEN** cargo invokes rustc, compiles the crate, and produces a binary
- **AND** cargo exits 0

### Requirement: Self-hosting test suite passes compilation tests
The self-hosting VM test suite SHALL pass all compilation-related FUNC_TESTs that were passing before the abort regression.

#### Scenario: VM test suite runs to completion
- **WHEN** `nix build .#self-hosting-test && ./result/bin/functional-test` is run
- **THEN** the test suite completes with 0 compilation test failures due to exit=134
- **AND** snix-build-simple, cargo-build, rustc-direct-link tests all PASS
