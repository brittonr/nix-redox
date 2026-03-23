## ADDED Requirements

### Requirement: VM test precompiles WASM on the host
The test infrastructure SHALL compile a hello-world WASM module to Pulley bytecode (`.cwasm`) during the Nix build phase using the host's Wasmtime.

#### Scenario: Host-side precompilation produces cwasm
- **WHEN** the VM test derivation builds
- **THEN** a `hello.cwasm` file is produced by running `wasmtime compile --target pulley64 hello.wasm` with the host Wasmtime binary

### Requirement: VM test includes wasmtime and test module in disk image
The test disk image SHALL contain both the cross-compiled `wasmtime` binary and the precompiled `.cwasm` test module.

#### Scenario: Disk image contains test artifacts
- **WHEN** the test disk image is built
- **THEN** `/bin/wasmtime` exists on the Redox filesystem
- **AND** a precompiled `.cwasm` test module exists at a known path (e.g., `/tmp/hello.cwasm`)

### Requirement: VM test executes WASM module on Redox and validates output
The test script SHALL run the precompiled WASM module under Wasmtime on the booted Redox VM and check for expected output.

#### Scenario: Hello world WASM runs successfully
- **WHEN** the Redox VM boots and runs `wasmtime run /tmp/hello.cwasm`
- **THEN** the process exits with code 0
- **AND** stdout contains "Hello, World!" or equivalent expected output

#### Scenario: Test reports PASS/FAIL
- **WHEN** the test script completes
- **THEN** it emits `FUNC_TEST:wasmtime-hello:PASS` on success
- **OR** `FUNC_TEST:wasmtime-hello:FAIL` on failure
