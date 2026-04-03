## ADDED Requirements

### Requirement: rustc target queries complete without panic
`rustc --print cfg` and `rustc --print sysroot` SHALL exit 0 on the self-hosting image when `RAYON_NUM_THREADS` and `LD_LIBRARY_PATH` are set correctly. LLVM session initialization SHALL not panic due to unimplemented syscalls, missing procfs, or environment variable lookups.

#### Scenario: rustc --print cfg exits 0
- **WHEN** the self-hosting image boots with the correct environment (`RAYON_NUM_THREADS=4`, `LD_LIBRARY_PATH` set)
- **AND** the user runs `rustc --print cfg`
- **THEN** rustc prints target configuration triples and exits 0
- **AND** no "fatal runtime error" or "abort" appears in stderr

#### Scenario: rustc --print sysroot exits 0
- **WHEN** the user runs `rustc --print sysroot`
- **THEN** rustc prints the sysroot path and exits 0

### Requirement: rustc compiles and links Rust source files
`rustc` invoked with a source file, linker, and output path SHALL produce an executable binary. Both the compilation (LLVM codegen) and link (via cc wrapper or ld.lld) phases SHALL succeed.

#### Scenario: rustc compiles and links an empty main
- **WHEN** the user runs `rustc -o /tmp/empty -C linker=cc /tmp/empty.rs` where empty.rs contains `fn main() {}`
- **THEN** rustc produces `/tmp/empty` and exits 0
- **AND** `/tmp/empty` executes and exits 0

#### Scenario: rustc compiles and links a hello world
- **WHEN** the user runs `rustc -o /tmp/hello -C linker=cc /tmp/hello.rs` where hello.rs contains `fn main() { println!("hello"); }`
- **THEN** rustc produces `/tmp/hello` and exits 0
- **AND** `/tmp/hello` prints "hello" and exits 0

### Requirement: snix starts without abort
`snix` SHALL initialize its evaluator, store, and CLI parser without panicking. `snix --version` and `snix eval --expr "1 + 1"` SHALL exit 0.

#### Scenario: snix --version exits 0
- **WHEN** the user runs `snix --version`
- **THEN** snix prints its version string and exits 0
- **AND** the process does not exit 134 (abort)

#### Scenario: snix eval works
- **WHEN** the user runs `snix eval --expr "1 + 1"`
- **THEN** snix prints `2` and exits 0

### Requirement: cargo build compiles a hello world project
`cargo build` in a minimal Rust project directory SHALL invoke rustc, compile the crate, and produce a binary.

#### Scenario: cargo build hello world
- **WHEN** the user creates a project with `Cargo.toml` and `src/main.rs` containing `fn main() { println!("hello"); }`
- **AND** runs `cargo build` with `CARGO_BUILD_JOBS=2`, `RAYON_NUM_THREADS=4`, `LD_LIBRARY_PATH`, and `CARGO_HOME` set
- **THEN** cargo compiles the crate and exits 0
- **AND** the resulting binary in `target/x86_64-unknown-redox/debug/` runs and prints "hello"

### Requirement: Self-hosting test compilation tests pass
All FUNC_TESTs that exercise rustc compilation, cargo build, and snix build SHALL pass in the self-hosting test suite.

#### Scenario: test suite compilation tests pass
- **WHEN** `nix build .#self-hosting-test` builds the test image
- **AND** the VM test runs to completion
- **THEN** `FUNC_TEST:rustc-version:PASS`, `FUNC_TEST:rustc-print-cfg:PASS`, `FUNC_TEST:two-step-compile:PASS`, `FUNC_TEST:hello-two-step:PASS`, and `FUNC_TEST:cargo-build-hello:PASS` all appear in serial output
