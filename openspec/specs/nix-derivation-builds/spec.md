## MODIFIED Requirements

### Requirement: snix-compile goes through snix build
The snix self-compile test SHALL invoke `snix build --file /usr/src/snix-redox/build.nix` instead of running `cargo build --offline` directly. The builder script (`build-snix.sh`) SHALL be pre-installed in the snix source bundle. The compiled snix binary SHALL be produced in a `/nix/store/` output path. The build execution SHALL use upstream `derivation_into_build_request()` for environment setup, with temp dir paths substituted to the actual build directory.

Additionally, the local builder SHALL handle derivations whose build scripts invoke the CC wrapper to compile C source code via clang. The per-path sandbox SHALL grant read-only access to system profile tool paths (`/nix/system/profile/bin/cc`, `clang`, `ld.lld`) and sysroot headers (`/usr/lib/redox-sysroot/`). The sandbox SHALL allow build scripts to create and link against static C libraries produced by cc-rs.

snix SHALL initialize without panicking — its evaluator, store resolution, and CLI argument parsing SHALL complete before any build work begins. If snix previously exited 134 (abort) during initialization, that init path SHALL be fixed so `snix build --expr` reaches the builder.

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

#### Scenario: snix init does not abort
- **WHEN** the user runs `snix --version` or `snix eval --expr "1"`
- **THEN** snix exits 0 (not 134)
- **AND** no "relibc: abort() called" appears in output
