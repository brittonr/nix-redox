## ADDED Requirements

### Requirement: snix-compile goes through snix build
The snix self-compile test SHALL invoke `snix build --file /usr/src/snix-redox/build.nix` instead of running `cargo build --offline` directly. The builder script (`build-snix.sh`) SHALL be pre-installed in the snix source bundle. The compiled snix binary SHALL be produced in a `/nix/store/` output path.

#### Scenario: snix self-compile via snix build
- **WHEN** the self-hosting test reaches the snix-compile phase
- **THEN** it runs `snix build --file /usr/src/snix-redox/build.nix` and the output path contains a working `snix` binary at `$out/bin/snix`

#### Scenario: snix-compile PASS verdict
- **WHEN** `snix build` succeeds and the output binary runs `--version` without error
- **THEN** the test emits `FUNC_TEST:snix-compile:PASS`

#### Scenario: snix-compile FAIL on build failure
- **WHEN** `snix build` exits non-zero or the output binary is missing
- **THEN** the test emits `FUNC_TEST:snix-compile:FAIL:<reason>` with build log context

### Requirement: rg-build goes through snix build
The ripgrep build test SHALL invoke `snix build --file /usr/src/ripgrep/build.nix` instead of creating an inline flake.nix. The builder script (`build-ripgrep.sh`) and `build.nix` SHALL be pre-installed in the ripgrep source bundle. The compiled `rg` binary SHALL be produced in a `/nix/store/` output path.

#### Scenario: ripgrep build via snix build
- **WHEN** the self-hosting test reaches the rg-build phase
- **THEN** it runs `snix build --file /usr/src/ripgrep/build.nix` and the output path contains a working `rg` binary at `$out/bin/rg`

#### Scenario: rg-build PASS verdict
- **WHEN** `snix build` succeeds and `$out/bin/rg --version` outputs a line containing "ripgrep"
- **THEN** the test emits `FUNC_TEST:rg-build:PASS`

#### Scenario: rg-build FAIL on build failure
- **WHEN** `snix build` exits non-zero or the binary is missing
- **THEN** the test emits `FUNC_TEST:rg-build:FAIL:<reason>` with build stderr context

### Requirement: Source bundles include build.nix and builder scripts
The `snix-source-bundle.nix` SHALL produce a bundle containing `build.nix` and `build-snix.sh` alongside the existing source tree. The `ripgrep-source-bundle.nix` SHALL produce a bundle containing `build.nix` and `build-ripgrep.sh`. These files SHALL be usable directly by `snix build --file`.

#### Scenario: snix source bundle contents
- **WHEN** the snix source bundle is built on the host
- **THEN** the output directory contains `build.nix`, `build-snix.sh`, `Cargo.toml`, `Cargo.lock`, `src/`, `vendor/`, and `.cargo/config.toml`

#### Scenario: ripgrep source bundle contents
- **WHEN** the ripgrep source bundle is built on the host
- **THEN** the output directory contains `build.nix`, `build-ripgrep.sh`, `Cargo.toml`, `Cargo.lock`, `crates/`, `vendor/`, and `.cargo/config.toml`

### Requirement: Builder scripts use polling timeout pattern
Builder scripts for snix and ripgrep SHALL run `cargo build --offline` in the background with the standard Redox polling+timeout pattern (background PID, `kill -0` loop, `/scheme/sys/uname` poll, configurable MAX_TIME). The snix builder SHALL use MAX_TIME=1800 (30 min). The ripgrep builder SHALL use MAX_TIME=600 (10 min) with up to 3 retry attempts.

#### Scenario: snix builder timeout
- **WHEN** cargo build runs longer than MAX_TIME seconds
- **THEN** the builder kills the cargo process and exits non-zero

#### Scenario: ripgrep builder retry
- **WHEN** cargo build fails on the first attempt but succeeds on retry
- **THEN** the builder continues and produces the output binary

### Requirement: cargo config included in source bundles
Each source bundle's `.cargo/config.toml` SHALL include the complete configuration needed for building: vendor source replacement, `jobs = 2`, `target = "x86_64-unknown-redox"`, and `linker = "/nix/system/profile/bin/cc"`. Builder scripts SHALL NOT generate or overwrite cargo config.

#### Scenario: snix source bundle cargo config
- **WHEN** the snix source bundle is built
- **THEN** `.cargo/config.toml` contains `jobs = 2`, `target = "x86_64-unknown-redox"`, vendor source replacement, and linker setting

#### Scenario: ripgrep source bundle cargo config
- **WHEN** the ripgrep source bundle is built
- **THEN** `.cargo/config.toml` contains `jobs = 2`, `target = "x86_64-unknown-redox"`, vendor source replacement, and linker setting

### Requirement: Test output in Nix store
Both snix-compile and rg-build test outputs SHALL be registered `/nix/store/` paths produced by `snix build`. The test script SHALL verify the output path starts with `/nix/store/`.

#### Scenario: snix-compile output in store
- **WHEN** snix self-compile succeeds
- **THEN** the output path starts with `/nix/store/` and contains `bin/snix`

#### Scenario: rg-build output in store
- **WHEN** ripgrep build succeeds
- **THEN** the output path starts with `/nix/store/` and contains `bin/rg`
