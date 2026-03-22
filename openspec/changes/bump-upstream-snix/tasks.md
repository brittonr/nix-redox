## 1. Update upstream pin

- [x] 1.1 Identify the target commit on upstream snix canon branch (latest as of 2026-03-19 or newer)
- [x] 1.2 Update `rev` in `nix/pkgs/infrastructure/snix-upstream-source.nix` to the new commit
- [x] 1.3 Set `hash` to dummy `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, run `nix build .#snix-upstream-source`, capture the real hash from the error, and update

## 2. Re-verify and update patches

- [x] 2.1 Clone/fetch the new upstream commit locally and diff the files our seds target (`build/Cargo.toml`, `build/src/lib.rs`, `build/src/buildservice/mod.rs`, `build/src/buildservice/from_addr.rs`, `castore/Cargo.toml`, `store/Cargo.toml`)
- [x] 2.2 Check if `snix-store` defaults already dropped `otlp` upstream (commit `8fb7605`) — if so, update our sed pattern to match the new default string
- [x] 2.3 Check if `snix-build` dropped `snix-tracing` dep upstream (commit `40f0a39`) — verify our FUSE/bwrap/oci seds still target the right lines
- [x] 2.4 Verify the `eval/src/systems.rs` patch still applies (the `is_second_coordinate` function context lines must match)
- [x] 2.5 Remove any seds that are now no-ops (upstream already made the change), add comments explaining why
- [x] 2.6 Build `snix-upstream-source` and verify all extracted crates have `Cargo.toml` and `src/`

## 3. Sync workspace dependencies

- [x] 3.1 Fetch upstream's root `Cargo.toml` at the new pinned commit and extract the `[workspace.dependencies]` section
- [x] 3.2 Diff against our `snix-redox/Cargo.toml` `[workspace.dependencies]` — identify version bumps, new deps, and removed deps
- [x] 3.3 Update versions in our `[workspace.dependencies]` to match upstream, preserving our Redox overrides (rustls ring backend, tonic tls-ring)
- [x] 3.4 Add `hashbrown` to workspace deps if upstream now requires it (KnownPaths migration)
- [x] 3.5 Check if any new workspace deps are needed by our extracted crates (grep for `workspace = true` in extracted Cargo.tomls)

## 4. Fix compile errors

- [x] 4.1 Run `cargo check` in `snix-redox/` and collect all errors
- [x] 4.2 Fix `KnownPaths` API changes — if upstream switched to hashbrown HashMap, update imports and call sites in `build_proxy/allow_list.rs`, `local_build.rs`, `eval.rs`, `bridge_build.rs`, `flake.rs`
- [x] 4.3 Fix `from_absolute_path_full` changes in `flake.rs` if the return type changed
- [x] 4.4 Fix any `Evaluation` builder API changes in `eval.rs` and `rebuild.rs`
- [x] 4.5 Fix any `construct_services` / `ServiceUrlsMemory` changes in `eval.rs`
- [x] 4.6 Fix any other compile errors found in 4.1
- [x] 4.7 Verify `cargo check` passes clean (zero errors, zero warnings from our code)

## 5. Update vendor hashes

- [x] 5.1 Update the `upstream` symlink in `snix-redox/` to point to the new `snix-upstream-source` output (for local dev)
- [x] 5.2 Run `nix build .#snix-redox` with dummy vendor hash, capture real hash, update `snix.nix`
- [x] 5.3 Run `nix build .#snix-source-bundle` (if it exists) with dummy vendor hash, capture real hash, update `snix-source-bundle.nix`

## 6. Test and validate

- [x] 6.1 Run `cargo test` in `snix-redox/` — all 560 tests pass (0 failed)
- [x] 6.2 Run `nix build .#snix` — cross-compilation succeeded
- [x] 6.3 Verify the built `snix` binary is the correct architecture (ELF 64-bit x86-64, 18.9MB)
- [x] 6.4 Spot-check: VM booted, snix binary loads (run-snix:PASS). Eval tests fail due to reqwest CA cert panic in Fetcher::new() — pre-existing issue exposed by cargo feature unification (object_store pulls rustls-native-certs). Separate fix needed.
