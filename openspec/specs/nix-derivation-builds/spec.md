## MODIFIED Requirements

### Requirement: Directory output derivations produce correct results

The local builder SHALL handle derivations whose `$out` is a directory tree (not just a single file). After the builder exits 0, snix SHALL verify the output directory exists, compute NAR hash over the directory tree, and register the output. Tests that create `$out/bin/greeting` and `$out/version` SHALL find those files after the build.

#### Scenario: Directory output with subdirectories
- **WHEN** a builder runs `mkdir -p $out/bin && echo hello > $out/bin/greeting`
- **THEN** `snix build` returns the output path and `$out/bin/greeting` contains "hello"

### Requirement: Flake installable evaluation and building works on Redox

`snix build .#hello` (or `snix build /path#attr`) SHALL evaluate the flake, resolve locked inputs, and build the derivation on Redox. Input resolution SHALL handle `path` type inputs without network access. The test flake at `/usr/src/test-flake` provides a minimal `hello` package that prints "Hello from flake!".

#### Scenario: Flake build from local path
- **WHEN** the user runs `snix build "/usr/src/test-flake#hello"`
- **THEN** the output contains `bin/hello` that prints "Hello from flake!"

#### Scenario: Flake build caching
- **WHEN** the same flake installable is built twice
- **THEN** the second build returns the same output path without re-building

### Requirement: Cargo-based derivations build inside the sandbox

Derivations that invoke cargo (cc-rs, workspaces, ripgrep) SHALL build successfully inside the per-path proxy sandbox. The proxy sandbox restricts scheme access (blocks `display:`, `disk:`, `irq:`, etc.) and filters `file:` access to declared inputs plus writable output/temp paths. The proxy SHALL keep its real redoxfs I/O off the scheme event-loop thread by forwarding those operations to a dedicated worker thread. Builder derivations SHALL use bash (not Ion) when they need to set HOME or other protected variables, and SHALL vendor all transitive build-tool dependencies (e.g., `shlex` for `cc` 1.2.x). Cargo vendor paths SHALL match the layout produced by `fetchCargoVendor` (typically `vendor/source-registry-0/`).

Note: If proxy setup fails at runtime, snix falls back to the scheme-only sandbox and emits a warning.

#### Scenario: cc-rs build succeeds in sandbox
- **WHEN** a derivation runs `cargo build` on a crate with `cc::Build::new().file("foo.c").compile("foo")`
- **THEN** the build succeeds: clang compiles the C file and the final binary links against the static library

#### Scenario: Workspace build succeeds in sandbox
- **WHEN** a derivation runs `cargo build` on a workspace with a library crate and a binary crate
- **THEN** both crates compile and the binary runs correctly

#### Scenario: Ripgrep 33-crate build succeeds
- **WHEN** `snix build --file /usr/src/ripgrep/build-ripgrep.nix` runs
- **THEN** the output contains a working `rg` binary that can search files

### Requirement: Source-based system rebuild works

`snix system rebuild --source` SHALL evaluate configuration.nix, resolve package sources, build derivations from source, and create a new system generation. Dry-run mode (`--dry-run`) SHALL show what would change without modifying the system.

#### Scenario: Source rebuild dry-run
- **WHEN** the user runs `snix system rebuild --source --dry-run`
- **THEN** snix evaluates the configuration and shows planned changes without modifying the system

#### Scenario: Source rebuild creates generation
- **WHEN** the user runs `snix system rebuild --source`
- **THEN** a new generation is created and the system manifest is updated

### Requirement: snix-compile goes through snix build
The snix self-compile test SHALL invoke `snix build --file /usr/src/snix-redox/build.nix` instead of running `cargo build --offline` directly. The builder script (`build-snix.sh`) SHALL be pre-installed in the snix source bundle. The compiled snix binary SHALL be produced in a `/nix/store/` output path. The build execution SHALL use upstream `derivation_into_build_request()` for environment setup, with temp dir paths substituted to the actual build directory.

Additionally, the local builder SHALL handle derivations whose build scripts invoke the CC wrapper to compile C source code via clang. The per-path sandbox SHALL grant read-only access to system profile tool paths (`/nix/system/profile/bin/cc`, `clang`, `ld.lld`) and sysroot headers (`/usr/lib/redox-sysroot/`). The sandbox SHALL allow build scripts to create and link against static C libraries produced by cc-rs.

snix SHALL initialize without panicking — its evaluator, store resolution, and CLI argument parsing SHALL complete before any build work begins. If snix previously exited 134 (abort) during initialization, that init path SHALL be fixed so `snix build --expr` reaches the builder.

The self-compile dependency graph SHALL remain buildable on Redox even when it includes allocator-related C build steps. If the Redox build selects `libmimalloc-sys` or another allocator crate with C sources, that C compilation SHALL succeed with the Redox clang/sysroot toolchain. If that allocator path is not Redox-safe, the Redox build SHALL select an alternative allocator configuration that still produces a working `snix` binary without changing CLI-visible behavior.

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

#### Scenario: libmimalloc-sys path builds on Redox when selected
- **GIVEN** the chosen Redox self-build still includes `libmimalloc-sys`
- **WHEN** `snix build --file /usr/src/snix-redox/build.nix` runs on the guest
- **THEN** the derivation does not fail in `c_src/mimalloc/v2/src/static.c` with clang/stdatomic type errors
- **AND** the build continues to a working `$out/bin/snix`

#### Scenario: allocator fallback remains behaviorally equivalent on Redox
- **GIVEN** the chosen Redox self-build excludes `libmimalloc-sys` in favor of a Redox-safe allocator configuration
- **WHEN** the resulting `snix` binary is run on Redox
- **THEN** `snix --version` succeeds
- **AND** `snix eval --expr "1 + 1"` returns `2`
- **AND** the self-hosted build result still installs a working `$out/bin/snix`
