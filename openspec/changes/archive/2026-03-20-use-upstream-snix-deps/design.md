## Context

snix-redox depends on two upstream snix crates (`nix-compat`, `snix-eval`) vendored locally, and reimplements derivation/fetcher builtins, `KnownPaths`, and the `EvalIO` implementation from `snix-glue`. The upstream snix workspace has 18 crates. The key ones:

- **nix-compat** — Nix format compatibility (NAR, narinfo, derivations, store paths, nixhash)
- **snix-eval** — Nix language bytecode VM
- **snix-glue** — Connects eval to store: `KnownPaths`, `derivation_builtins`, `fetcher_builtins`, `snix_store_io`, `import_builtins`
- **snix-store** — Store abstractions: `PathInfoService`, NAR calculation, binary cache client, import
- **snix-castore** — Content-addressed store: `BlobService`, `DirectoryService`, chunking
- **snix-build** — Build service abstraction: `BuildService` trait, `DummyBuildService`

All crates above snix-eval use tokio. irohd (already shipping on Redox) proves tokio 1.50 works: `rt-multi-thread`, mio, reqwest, 314 crates cross-compile and run on Redox. The `poll()` issue in AGENTS.md is specific to pipe multiplexing in `std::process`, not mio's socket-based event loop (which uses Redox's native `event:` scheme).

The build system uses `buildFromUnitGraph` with per-crate JSON build plans. irohd demonstrates the pattern for crate-level `extraCrateOverrides` to patch crates that assume Linux (quinn-udp, netwatch, surge-ping, netdev).

## Goals / Non-Goals

**Goals:**
- Use upstream `nix-compat` directly with feature flags
- Use upstream `snix-eval` with Nix-applied Redox systems patch
- Use upstream `snix-glue` for derivation builtins, fetcher builtins, KnownPaths, and EvalIO
- Use upstream `snix-store` for PathInfo types, NAR calculation, import utilities
- Use upstream `snix-castore` for BlobService/DirectoryService interfaces (in-memory backends for our use case)
- Use upstream `snix-build` for the BuildService trait (with our own Redox implementation)
- Add tokio runtime to snix-redox
- Delete vendored forks and reimplemented glue code
- All 607 tests continue to pass
- Redox-specific code (build_proxy, stored, profiled, sandbox, scheme daemons) unchanged

**Non-Goals:**
- Upstreaming the Redox systems patch (we apply it via Nix)
- Using upstream's Linux-specific build backends (bubblewrap, OCI)
- Replacing our filesystem-based store with upstream's content-addressed chunked store for on-disk layout
- Using upstream's gRPC service endpoints (we don't run a Nix daemon)
- Cloud storage backends (S3/GCS/Azure)
- FUSE/virtiofs castore backends

## Decisions

### 1. Upstream source extraction via Nix derivation

A Nix derivation (`snix-upstream-source`) fetches the upstream snix monorepo via `fetchFromGitea` at a pinned commit, extracts the crates we need (`nix-compat`, `nix-compat-derive`, `eval`, `eval/builtin-macros`, `glue`, `store`, `castore`, `build`, `serde`, `tracing`), and applies the Redox systems patch. The derivation output is referenced by Cargo.toml via path deps.

**Alternative considered**: Git dep in Cargo.toml. Rejected: git deps in Cargo.lock break `fetchCargoVendor` FOD reference checks in Nix 2.31+.

### 2. Tokio runtime in snix-redox

snix-redox gains a tokio runtime. The main thread starts a multi-thread runtime (matching irohd's pattern). The evaluator's synchronous `EvalIO` calls use `tokio_handle.block_on()` to bridge into upstream's async store/fetch code — this is exactly what upstream's `SnixStoreIO` already does.

The runtime is only used for store operations and fetching. Build execution still uses `std::process::Command` with the existing Redox sandbox. The scheme daemons (stored, profiled) remain synchronous (they use Redox scheme protocol, not tokio).

### 3. In-memory store services for evaluation

Upstream `SnixStoreIO` requires `BlobService`, `DirectoryService`, `PathInfoService`, and `NarCalculationService` trait objects. For snix-redox's use case (eval + local builds on Redox), we use in-memory implementations from `snix-store`:

```rust
let (blob_service, directory_service, path_info_service, nar_calculation_service) =
    construct_services(ServiceUrlsMemory::parse_from(std::iter::empty::<&str>())).await;
```

This is the same pattern upstream's own tests use. The in-memory store is ephemeral — it lives for the duration of an evaluation/build session. Our existing `PathInfoDb` (JSON files on disk) remains for persistent store registration, used after builds complete.

### 4. Custom BuildService for Redox

Upstream's `BuildService` trait has a single method: `do_build(BuildRequest) -> BuildResult`. We implement this trait with our existing Redox build logic (namespace sandboxing, `std::process::Command`, build_proxy). During evaluation, when upstream's `SnixStoreIO` needs to build a dependency, it calls our `RedoxBuildService::do_build()`, which executes the builder inside a Redox namespace sandbox.

For the initial migration, `DummyBuildService` (upstream's no-op implementation) is sufficient — it returns errors, and build-on-demand during evaluation falls back to `StdIO` (filesystem). Our explicit `snix build` command continues to use the existing `local_build::build_needed()` pipeline. The custom `BuildService` integration is a follow-up.

### 5. What gets deleted vs. what stays

**Deleted** (replaced by upstream):
- `nix-compat-redox/` — 17k LOC → upstream `nix-compat`
- `nix-compat-derive/` → upstream `nix-compat-derive`
- `snix-eval-vendored/` — 17k LOC → upstream `snix-eval`
- `src/derivation_builtins.rs` — 516 LOC → upstream `snix-glue::builtins::derivation`
- `src/known_paths.rs` — 85 LOC → upstream `snix-glue::known_paths`
- `src/fetchers.rs` fetcher builtins — ~300 LOC → upstream `snix-glue::builtins::fetchers`
- Hand-rolled tar parser — ~150 LOC → upstream uses `tokio-tar`

**Adapted** (rewritten to use upstream interfaces):
- `src/eval.rs` — use upstream `add_derivation_builtins()`, `add_fetcher_builtins()`, `add_import_builtins()`
- `src/snix_io.rs` — wrap or replace with upstream `SnixStoreIO`
- `src/fetchers.rs` build-time execution — keep `fetch_to_store()` and `verify_fetch_hash()`, but use upstream types

**Kept unchanged** (Redox-specific, no upstream equivalent):
- `src/local_build.rs` — Redox build execution with namespace sandbox
- `src/build_proxy/` — per-path filesystem proxy sandbox
- `src/sandbox.rs` — Redox namespace sandboxing
- `src/stored/` — store: scheme daemon
- `src/profiled/` — profile: scheme daemon
- `src/cache.rs` — binary cache client (may later switch to upstream)
- `src/store.rs` — local store management (GC, closures, roots)
- `src/pathinfo.rs` — JSON-based PathInfoDb
- `src/system.rs`, `src/rebuild.rs`, `src/channel.rs` — system management
- `src/flake.rs` — flake support
- `src/install.rs`, `src/vendor.rs` — package management

### 6. Crate-level Redox patches via extraCrateOverrides

The upstream dependency tree introduces crates that assume Linux or lack Redox support. Following irohd's established pattern, these get `extraCrateOverrides` in `nix/flake-modules/packages.nix`. Expected patches:

- **reqwest** — may need TLS/DNS backend selection for Redox
- **tokio-tar** — should work (uses tokio::fs, std::io)
- **walkdir** — should work (pure Rust)
- **fuse-backend-rs** — gated behind `fs` feature, not enabled
- **prost/tonic** — compile but unused code paths; may need stubs if build scripts probe the system
- **redb** — embedded database; if snix-castore uses it unconditionally, may need feature gating

Many of these crates already compile for Redox via the irohd build (shared dependency tree). The incremental cost of adding snix-glue's deps is lower than the full ~400 crates because of overlap with irohd.

### 7. Build plan regeneration

The build plan grows from ~161 to ~400+ crates. This increases the one-time build from scratch but subsequent builds only rebuild changed crates (per-crate Nix caching via `buildFromUnitGraph`). The `regenerate-build-plan.sh` script handles upstream source setup before running `cargo unit-graph`.

## Risks / Trade-offs

- **[Upstream API breaks]** → Pin to a specific commit hash. Bump deliberately after running tests.
- **[Build time increase]** → ~400 crates vs ~161. Mitigated by per-crate Nix caching — only the first build is slow. Many crates overlap with irohd's build.
- **[Binary size increase]** → tokio + tonic + prost add to the binary. Mitigated by `opt-level = "s"` and LTO (already configured). Unused gRPC code may be DCE'd. Monitor and strip if needed.
- **[Disk image size]** → If the snix binary grows significantly, disk image size may need adjustment. Currently 768MB default, 1024MB graphical.
- **[New crate patching burden]** → Each upstream dep that doesn't compile on Redox needs an `extraCrateOverride`. irohd's experience (6 crate patches for 314 crates) suggests this is manageable.
- **[snix-castore in-memory only]** → We don't use the content-addressed chunked store on disk. The in-memory backend means evaluation state is ephemeral. This matches our current behavior.
- **[Two store implementations]** → Upstream's in-memory castore coexists with our filesystem `PathInfoDb`. This is intentional — upstream's store is for evaluation-time state, ours is for persistent on-disk registration.
