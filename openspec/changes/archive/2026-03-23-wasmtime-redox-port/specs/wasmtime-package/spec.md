## ADDED Requirements

### Requirement: Wasmtime Nix package cross-compiles for Redox
The build system SHALL produce a `wasmtime` binary for `x86_64-unknown-redox` via `nix build .#wasmtime-redox` using the existing `mk-userspace.nix` infrastructure.

#### Scenario: Nix build succeeds
- **WHEN** `nix build .#wasmtime-redox` is invoked
- **THEN** the output contains a statically-linked `wasmtime` binary at `$out/bin/wasmtime` targeting `x86_64-unknown-redox`

#### Scenario: Binary is ELF for Redox
- **WHEN** `file $out/bin/wasmtime` is run on the build output
- **THEN** the output indicates an x86-64 ELF binary (Redox uses standard ELF)

### Requirement: Wasmtime uses Pulley interpreter backend
The package SHALL build Wasmtime with the Pulley interpreter enabled and signal-based trap handling disabled, so execution does not depend on `ucontext_t`, `sigaltstack`, or signal handler register access.

#### Scenario: Feature flags exclude signal dependencies
- **WHEN** the Nix package builds Wasmtime
- **THEN** Cargo features `async`, `pooling-allocator`, and all `wasi-*` features are disabled
- **AND** features `pulley`, `cranelift`, `runtime`, `std` are enabled

### Requirement: Vendored dependencies are patched for Redox
The package SHALL vendor Wasmtime's dependency tree and apply patches to crates that fail to compile for `x86_64-unknown-redox`. Each patched crate SHALL have its `.cargo-checksum.json` regenerated.

#### Scenario: rustix mm module compiles
- **WHEN** the vendored `rustix` crate is compiled for Redox
- **THEN** the `mm` module compiles without errors (madvise already excluded for Redox upstream)

#### Scenario: Patched crate checksums are valid
- **WHEN** cargo resolves vendored dependencies during the build
- **THEN** no checksum mismatch errors occur for patched crates

### Requirement: Package is available in flake outputs
The Wasmtime package SHALL be exposed as a flake package output so it can be included in Redox system profiles.

#### Scenario: Flake exposes wasmtime-redox
- **WHEN** `nix flake show` is run
- **THEN** `packages.x86_64-linux.wasmtime-redox` is listed

### Requirement: Wasmtime can load precompiled Pulley modules
The cross-compiled `wasmtime` binary SHALL load and execute `.cwasm` files that were compiled with `wasmtime compile --target pulley64` on the host.

#### Scenario: Precompiled module round-trips
- **WHEN** a `.wasm` module is compiled to `.cwasm` with `wasmtime compile --target pulley64` on the build host
- **AND** the `.cwasm` file is copied to the Redox disk image
- **AND** `wasmtime run module.cwasm` is invoked on Redox
- **THEN** the module executes and produces the expected output
