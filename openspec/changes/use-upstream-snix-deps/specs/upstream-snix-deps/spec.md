## ADDED Requirements

### Requirement: Upstream nix-compat source extraction
The build system SHALL fetch the upstream snix monorepo at a pinned commit and extract nix-compat, nix-compat-derive, snix-eval, snix-eval-builtin-macros, snix-glue, snix-store, snix-castore, snix-build, snix-serde, and snix-tracing crate sources into a Nix derivation output.

#### Scenario: All required crates extracted
- **WHEN** the Nix derivation `snix-upstream-source` is built
- **THEN** the output contains Cargo.toml and src/ for each of: nix-compat, eval, glue, store, castore, build

#### Scenario: Redox systems patch applied to snix-eval
- **WHEN** the derivation is built
- **THEN** `eval/src/systems.rs` contains `"redox"` in the `is_second_coordinate()` match arms

### Requirement: snix-glue replaces reimplemented derivation builtins
snix-redox SHALL use upstream `snix-glue::builtins::add_derivation_builtins()` to register derivationStrict and placeholder builtins instead of the local `derivation_builtins.rs` implementation.

#### Scenario: Derivation output path matches upstream
- **WHEN** `snix eval --expr '(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath'` is evaluated
- **THEN** the result is `"/nix/store/xpcvxsx5sw4rbq666blz6sxqlmsqphmr-foo"` (same as upstream Nix and previous snix-redox)

#### Scenario: Fixed-output derivation paths match upstream
- **WHEN** a FOD with sha256 hash is evaluated
- **THEN** the output path matches upstream test vectors (e.g., `17wgs52s7kcamcyin4ja58njkf91ipq8-foo` for recursive sha256)

#### Scenario: Local derivation_builtins.rs deleted
- **WHEN** the migration is complete
- **THEN** `snix-redox/src/derivation_builtins.rs` does not exist

### Requirement: snix-glue replaces reimplemented fetcher builtins
snix-redox SHALL use upstream `snix-glue::builtins::add_fetcher_builtins()` to register fetchurl and fetchTarball builtins instead of the local fetcher builtin implementations.

#### Scenario: fetchurl produces correct store path
- **WHEN** `builtins.fetchurl { url = "..."; sha256 = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }` is evaluated
- **THEN** the result is a `/nix/store/` path matching the content hash

#### Scenario: fetchTarball produces correct store path
- **WHEN** `builtins.fetchTarball { url = "..."; sha256 = "..."; }` is evaluated
- **THEN** the result is a `/nix/store/` path with recursive (NAR) hash mode

### Requirement: snix-glue replaces reimplemented KnownPaths
snix-redox SHALL use upstream `snix-glue::known_paths::KnownPaths` instead of the local `known_paths.rs` implementation. The upstream version additionally tracks fetches via `add_fetch()`.

#### Scenario: Local known_paths.rs deleted
- **WHEN** the migration is complete
- **THEN** `snix-redox/src/known_paths.rs` does not exist

#### Scenario: Derivation registration works through upstream KnownPaths
- **WHEN** multiple derivations with dependencies are evaluated
- **THEN** `get_drv_by_drvpath()` and `get_hash_derivation_modulo()` return correct values matching upstream test vectors

### Requirement: Upstream SnixStoreIO used for EvalIO
snix-redox SHALL use upstream `snix-glue::snix_store_io::SnixStoreIO` as the `EvalIO` implementation, configured with in-memory store service backends.

#### Scenario: builtins.storeDir returns /nix/store
- **WHEN** `builtins.storeDir` is evaluated
- **THEN** the result is `"/nix/store"`

#### Scenario: Path import produces correct store path
- **WHEN** a local file is interpolated into a Nix string (triggering import_path)
- **THEN** the resulting store path matches the content-addressed NAR hash

#### Scenario: Store services use in-memory backends
- **WHEN** snix-redox initializes the evaluator
- **THEN** BlobService, DirectoryService, PathInfoService, and NarCalculationService are constructed with in-memory backends via `construct_services(ServiceUrlsMemory)`

### Requirement: Tokio runtime added
snix-redox SHALL initialize a tokio multi-thread runtime for async store/fetch operations. The runtime SHALL be used for evaluation-time I/O only.

#### Scenario: Tokio runtime starts on Redox
- **WHEN** snix starts on Redox OS
- **THEN** a tokio runtime with `rt-multi-thread` feature is created and runs without errors

#### Scenario: Scheme daemons remain synchronous
- **WHEN** snix stored or snix profiled commands are invoked
- **THEN** they run using synchronous Redox scheme protocol, not tokio

### Requirement: Upstream crate cross-compilation patches
Crates in the upstream snix dependency tree that do not compile for `x86_64-unknown-redox` SHALL receive `extraCrateOverrides` in the Nix build configuration, following the pattern established by irohd.

#### Scenario: Build succeeds for x86_64-unknown-redox
- **WHEN** `nix build .#snix` is run
- **THEN** the cross-compiled binary is produced without compilation errors

#### Scenario: Crate overrides documented
- **WHEN** a crate requires patching for Redox
- **THEN** the override is added to `nix/flake-modules/packages.nix` with a comment explaining the incompatibility

### Requirement: Vendored fork directories removed
After migration, the vendored fork directories SHALL be removed: `snix-redox/nix-compat-redox/`, `snix-redox/nix-compat-derive/`, `snix-redox/snix-eval-vendored/`.

#### Scenario: No vendored nix-compat source
- **WHEN** the migration is complete
- **THEN** `snix-redox/nix-compat-redox/` does not exist

#### Scenario: No vendored snix-eval source
- **WHEN** the migration is complete
- **THEN** `snix-redox/snix-eval-vendored/` does not exist

### Requirement: Build plan regeneration
The build plan SHALL be regenerated to include all upstream crate dependencies.

#### Scenario: Build plan reflects upstream deps
- **WHEN** `snix-build-plan.json` is regenerated
- **THEN** it contains entries for snix-glue, snix-store, snix-castore, snix-build, tokio, and their transitive dependencies

#### Scenario: Build plan regeneration script works
- **WHEN** `./regenerate-build-plan.sh` is run
- **THEN** the upstream source is prepared, `cargo unit-graph` runs, and the build plan is written

### Requirement: Source bundle updated
The source bundle derivation SHALL include the upstream crate sources and all vendored dependencies for offline builds on the Redox guest.

#### Scenario: Source bundle includes upstream sources
- **WHEN** the source bundle is built
- **THEN** it contains the upstream crate directories needed by Cargo.toml path deps

#### Scenario: Offline build works
- **WHEN** `cargo build --offline` is run inside the source bundle
- **THEN** compilation succeeds

### Requirement: All existing tests pass
All existing unit tests SHALL pass after the migration. Derivation output paths, NAR hashes, and store path computations SHALL produce identical results.

#### Scenario: Unit tests pass on host
- **WHEN** `cargo test --target x86_64-unknown-linux-gnu` is run
- **THEN** all existing tests pass

#### Scenario: Cross-compilation succeeds
- **WHEN** `nix build .#snix` is run
- **THEN** the snix binary is produced

#### Scenario: Redox system string works
- **WHEN** `snix eval --expr 'builtins.currentSystem'` runs on Redox
- **THEN** the result includes `"redox"`

#### Scenario: VM functional tests pass
- **WHEN** the snix binary is booted in a Redox VM
- **THEN** `snix eval --expr '1 + 1'` returns `2`
