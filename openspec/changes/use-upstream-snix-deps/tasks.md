## 1. Nix upstream source derivation

- [x] 1.1 Create `nix/pkgs/infrastructure/snix-upstream-source.nix` that fetches the snix monorepo via `fetchFromGitea` at pinned commit `eee477929d6b500936556e2f8a4e187d37525365`
- [x] 1.2 Extract nix-compat, nix-compat-derive, eval, eval/builtin-macros, glue, store, castore, build, serde, and tracing from the fetched source
- [x] 1.3 Apply `snix-redox/patches/0001-systems-add-redox-os-support.patch` to eval/src/systems.rs
- [x] 1.4 Verify the derivation builds successfully

## 2. Update Cargo.toml and dependencies

- [x] 2.1 Set up upstream source directory at `snix-redox/upstream/` (symlink to Nix derivation output for local dev)
- [x] 2.2 Update Cargo.toml: replace `nix-compat = { path = "nix-compat-redox" }` with `nix-compat = { path = "upstream/nix-compat", default-features = false, features = ["serde"] }`
- [x] 2.3 Update Cargo.toml: replace `snix-eval = { path = "snix-eval-vendored/snix-eval" }` with `snix-eval = { path = "upstream/eval", default-features = false, features = ["impure"] }`
- [x] 2.4 Add path deps for snix-glue, snix-store, snix-castore, snix-build (with appropriate feature flags — disable fuse, virtiofs, cloud, tonic-reflection, nix_tests)
- [x] 2.5 Add `tokio = { version = "1", features = ["rt-multi-thread", "sync", "macros", "fs"] }`
- [x] 2.6 Remove nix-compat-derive path dep (comes transitively through nix-compat)
- [x] 2.7 Remove `genawaiter` direct dep if upstream snix-eval re-exports what we need (deferred — used in files to be deleted in task group 4)
- [x] 2.8 Run `cargo generate-lockfile` and verify `cargo check --target x86_64-unknown-linux-gnu` succeeds

## 3. Rewrite eval.rs to use upstream builtins

- [x] 3.1 Replace `evaluate_with_state()` to construct a tokio runtime and use upstream `SnixStoreIO` with in-memory store services (`construct_services(ServiceUrlsMemory)`)
- [x] 3.2 Replace manual `add_builtins(derivation_builtins::builtins(...))` with upstream `add_derivation_builtins(eval_builder, io)`
- [x] 3.3 Replace manual fetcher builtin registration with upstream `add_fetcher_builtins(eval_builder, io)`
- [x] 3.4 Add upstream `add_import_builtins(eval_builder, io)` for `filterSource`, `path`, `storePath` builtins
- [x] 3.5 Keep `add_src_builtin("derivation", ...)` — handled by upstream `add_derivation_builtins` which includes it
- [x] 3.6 Verify all eval unit tests pass: `cargo test --target x86_64-unknown-linux-gnu -- eval` (44/44 pass)

## 4. Delete reimplemented glue modules

- [ ] 4.1 Delete `snix-redox/src/derivation_builtins.rs` (516 LOC)
- [ ] 4.2 Delete `snix-redox/src/known_paths.rs` (85 LOC)
- [ ] 4.3 Delete fetcher builtin code from `snix-redox/src/fetchers.rs` (keep `fetch_to_store`, `verify_fetch_hash`, `fetch_and_unpack` for build-time execution)
- [ ] 4.4 Rewrite or delete `snix-redox/src/snix_io.rs` — replaced by upstream `SnixStoreIO`
- [ ] 4.5 Update `src/lib.rs` and `src/main.rs` to remove references to deleted modules
- [ ] 4.6 Update `src/local_build.rs` to use upstream `KnownPaths` type (from `snix_glue::known_paths`)
- [ ] 4.7 Update `src/flake.rs` to use upstream `KnownPaths` and evaluation setup
- [ ] 4.8 Fix all remaining compilation errors from import path changes
- [ ] 4.9 Run full test suite: `cargo test --target x86_64-unknown-linux-gnu`

## 5. Cross-compilation crate patches

- [ ] 5.1 Attempt `nix build .#snix` and collect compilation errors for crates that don't support Redox
- [ ] 5.2 Add `extraCrateOverrides` in `nix/flake-modules/packages.nix` for each failing crate (follow irohd pattern: sed patches, stub files, cfg redirects)
- [ ] 5.3 Check for overlap with irohd's existing overrides (reqwest, ring, mio, tokio, socket2 may already work)
- [ ] 5.4 Stub out Linux-only snix-build backends (bubblewrap, OCI) — use `DummyBuildService` or cfg-gated stubs
- [ ] 5.5 Disable snix-castore features: no fuse, no virtiofs, no cloud
- [ ] 5.6 Handle prost/tonic compilation if they're pulled in transitionally — may need `--no-default-features` or stubs for build.rs probing
- [ ] 5.7 Iterate until `nix build .#snix` produces a binary

## 6. Regenerate build plan and source bundle

- [ ] 6.1 Update `regenerate-build-plan.sh` to prepare upstream source before `cargo unit-graph`
- [ ] 6.2 Run regeneration, commit updated `snix-build-plan.json`
- [ ] 6.3 Update `snix-source-bundle.nix` to copy `upstream/` instead of vendored directories
- [ ] 6.4 Recompute vendor hash in `snix-source-bundle.nix`
- [ ] 6.5 Verify `nix build` of the source bundle succeeds

## 7. Delete vendored forks

- [ ] 7.1 Delete `snix-redox/nix-compat-redox/` (17k LOC)
- [ ] 7.2 Delete `snix-redox/nix-compat-derive/`
- [ ] 7.3 Delete `snix-redox/snix-eval-vendored/` (17k LOC)
- [ ] 7.4 Verify `git status` shows expected deletions

## 8. Full validation

- [ ] 8.1 `cargo test --target x86_64-unknown-linux-gnu` — all tests pass
- [ ] 8.2 `nix build .#snix` — cross-compiled binary produced
- [ ] 8.3 `nix build` source bundle — produced with upstream sources
- [ ] 8.4 `nix flake check` — snix build check passes
- [ ] 8.5 Boot VM: `snix eval --expr '1 + 1'` returns 2
- [ ] 8.6 Boot VM: `snix eval --expr '(derivation { name = "test"; builder = "/bin/sh"; system = "x86_64-redox"; }).outPath'` evaluates correctly
- [ ] 8.7 Boot VM: `snix build --expr` with a simple derivation completes (tests build pipeline with upstream eval)
- [ ] 8.8 Measure binary size delta and document in commit message
