## ADDED Requirements

### Requirement: ripgrep builds successfully through snix on Redox

`snix build --file /usr/src/ripgrep/build.nix` SHALL produce a working ripgrep binary in the Nix store when run on a Redox guest with the self-hosting toolchain installed.

#### Scenario: Build completes with exit code 0
- **WHEN** `snix build --file /usr/src/ripgrep/build.nix` is executed on the Redox guest
- **THEN** the command exits with code 0 and prints a `/nix/store/...` output path to stdout

#### Scenario: Output binary exists and is executable
- **WHEN** the build succeeds and produces output path `$OUTPUT`
- **THEN** `$OUTPUT/bin/rg` exists and is executable

#### Scenario: Built binary reports its version
- **WHEN** `$OUTPUT/bin/rg --version` is executed
- **THEN** the output contains the string `ripgrep`

#### Scenario: Built binary performs text search
- **WHEN** a file contains lines `hello world`, `foo bar`, `hello redox` and `$OUTPUT/bin/rg "hello"` is run against it
- **THEN** at least 2 matching lines are returned

#### Scenario: Binary has reasonable size
- **WHEN** the build produces `$OUTPUT/bin/rg`
- **THEN** the binary is larger than 1MB (1000000 bytes)

### Requirement: Builder script sets a complete build environment

`build-ripgrep.sh` SHALL configure all environment variables needed for cargo to compile Rust crates with C dependencies on Redox.

#### Scenario: PATH includes toolchain binaries
- **WHEN** the builder script runs
- **THEN** PATH includes `/nix/system/profile/bin` so that `rustc`, `cargo`, `cc`, `llvm-ar`, and `lld-wrapper` are found

#### Scenario: AR is set for cc-rs crate
- **WHEN** a crate uses cc-rs to invoke the archiver
- **THEN** `AR` is set to `/nix/system/profile/bin/llvm-ar`

#### Scenario: Dynamic linker paths are set
- **WHEN** cargo invokes rustc to produce a binary
- **THEN** `LD_LIBRARY_PATH` includes `/nix/system/profile/lib` and `/usr/lib/rustc` so rustc can find its shared libraries

### Requirement: Builder reports full error context on failure

When the cargo build fails, the builder script SHALL emit enough error context for diagnosis without re-running the build.

#### Scenario: Build log is dumped on final failure
- **WHEN** cargo fails on the final retry attempt
- **THEN** the builder writes the full build log to stderr (not truncated to 4KB)

#### Scenario: Each attempt logs its outcome
- **WHEN** a cargo build attempt starts or finishes
- **THEN** the builder emits the attempt number and exit code to stderr

#### Scenario: Failing crate is identifiable
- **WHEN** cargo fails compiling a specific crate
- **THEN** the error output includes the crate name and the compiler/linker error message
