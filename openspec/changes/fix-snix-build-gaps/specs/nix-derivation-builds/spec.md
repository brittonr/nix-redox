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

Derivations that invoke cargo (cc-rs, workspaces, ripgrep) SHALL build successfully inside the scheme-only sandbox. The scheme-only sandbox restricts scheme access (blocks `display:`, `disk:`, `irq:`, etc.) while granting full `file:` (redoxfs) access. Builder derivations SHALL use bash (not Ion) when they need to set HOME or other protected variables, and SHALL vendor all transitive build-tool dependencies (e.g., `shlex` for `cc` 1.2.x). Cargo vendor paths SHALL match the layout produced by `fetchCargoVendor` (typically `vendor/source-registry-0/`).

Note: The per-path proxy sandbox (which would restrict filesystem access to an allow-list) is disabled due to a kernel deadlock. The scheme-only sandbox is the active default.

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
