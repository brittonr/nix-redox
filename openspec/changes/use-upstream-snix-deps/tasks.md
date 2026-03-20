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

- [x] 4.1 Delete `snix-redox/src/derivation_builtins.rs` (516 LOC) — module declarations removed from lib.rs/main.rs, file kept as dead code until physical delete in task 7
- [x] 4.2 Delete `snix-redox/src/known_paths.rs` (85 LOC) — module declarations removed, imports switched to snix_glue::known_paths
- [x] 4.3 Delete fetcher builtin code from `snix-redox/src/fetchers.rs` — rewrote to keep only build-time execution (fetch_to_store, verify_fetch_hash, fetch_and_unpack, tar extraction)
- [x] 4.4 Rewrite or delete `snix-redox/src/snix_io.rs` — module commented out in lib.rs/main.rs, replaced by upstream SnixStoreIO
- [x] 4.5 Update `src/lib.rs` and `src/main.rs` to remove references to deleted modules
- [x] 4.6 Update `src/local_build.rs` to use upstream `KnownPaths` type (from `snix_glue::known_paths`)
- [x] 4.7 Update `src/flake.rs` to use upstream `KnownPaths` and evaluation setup
- [x] 4.8 Fix all remaining compilation errors from import path changes
- [x] 4.9 Run full test suite: `cargo test --target x86_64-unknown-linux-gnu` — 563 pass, 0 fail

## 5. Cross-compilation crate patches

- [x] 5.1 Attempt `nix build .#snix` and collect compilation errors for crates that don't support Redox
- [x] 5.2 Add `extraCrateOverrides` in `nix/flake-modules/packages.nix` for each failing crate (protobuf, zstd-sys CC override)
- [x] 5.3 Check for overlap with irohd's existing overrides (ring already works via irohd)
- [x] 5.4 Stub out Linux-only snix-build backends — already cfg(target_os = "linux") gated upstream, removed fuse feature from snix-build→snix-castore dep
- [x] 5.5 Disable snix-castore features: no fuse, no virtiofs, no cloud (patched default features in source derivation)
- [x] 5.6 Handle prost/tonic: switched tls-aws-lc to tls-ring (aws-lc-sys uses glibc __isoc23_sscanf), added protoc/PROTO_ROOT/SNIX_BUILD_SANDBOX_SHELL overrides
- [x] 5.7 `nix build .#snix` produces binary — 18MB snix + 964K proxy_namespace_test, 371 crates compiled

## 6. Regenerate build plan and source bundle

- [x] 6.1 Update `regenerate-build-plan.sh` to prepare upstream source before `cargo unit-graph`
- [x] 6.2 Run regeneration, commit updated `snix-build-plan.json`
- [x] 6.3 Update `snix-source-bundle.nix` to copy `upstream/` instead of vendored directories
- [x] 6.4 Recompute vendor hash in `snix-source-bundle.nix`
- [x] 6.5 Verify `nix build` of the source bundle succeeds

## 7. Delete vendored forks

- [x] 7.1 Delete `snix-redox/nix-compat-redox/` (17k LOC)
- [x] 7.2 Delete `snix-redox/nix-compat-derive/`
- [x] 7.3 Delete `snix-redox/snix-eval-vendored/` (17k LOC)
- [x] 7.4 Verify `git status` shows expected deletions

## 8. Full validation

- [x] 8.1 `cargo test --target x86_64-unknown-linux-gnu` — 563 tests pass, 0 fail
- [x] 8.2 `nix build .#snix` — cross-compiled binary produced (18MB)
- [x] 8.3 `nix build` source bundle — produced with upstream sources (upstream/ + 597 vendored crates)
- [x] 8.4 `nix flake check` — snix-test passes (563 tests, needed SSL_CERT_FILE override on test derivation for reqwest CA cert init)
- [ ] 8.5 Boot VM: `snix eval --expr '1 + 1'` returns 2
- [ ] 8.6 Boot VM: `snix eval --expr '(derivation { name = "test"; builder = "/bin/sh"; system = "x86_64-redox"; }).outPath'` evaluates correctly
- [ ] 8.7 Boot VM: `snix build --expr` with a simple derivation completes (tests build pipeline with upstream eval)
- [x] 8.8 Measure binary size delta — 18MB (with opt-level=s, LTO, panic=abort), 371 crates
